#include "frames.h"

#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { MSG_ID_SUBSCRIBE = 0x626f7701, MSG_ID_FRAME = 0x626f7702 };

typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  uint64_t value; // nonce for SUBSCRIBE, seq for FRAME
} port_msg;

typedef struct {
  port_msg msg;
  mach_msg_max_trailer_t trailer;
} port_msg_rcv;

static kern_return_t send_port(mach_port_t dest, mach_msg_id_t id, mach_port_t port,
                               mach_msg_type_name_t disposition, uint64_t value, mach_msg_timeout_t timeout) {
  port_msg m = {0};
  m.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
  m.header.msgh_size = sizeof m;
  m.header.msgh_remote_port = dest;
  m.header.msgh_id = id;
  m.body.msgh_descriptor_count = 1;
  m.port.name = port;
  m.port.disposition = disposition;
  m.port.type = MACH_MSG_PORT_DESCRIPTOR;
  m.value = value;
  return mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, timeout,
                  MACH_PORT_NULL);
}

// Receive loop shared by both sides. Ends when the receive right is destroyed.
typedef void (*port_fn)(void *ctx, mach_msg_id_t id, mach_port_t port, uint64_t value);

static void receive_loop(mach_port_t rcv, port_fn fn, void *ctx) {
  for (;;) {
    port_msg_rcv m;
    kern_return_t kr = mach_msg(&m.msg.header, MACH_RCV_MSG, 0, sizeof m, rcv, MACH_MSG_TIMEOUT_NONE,
                                MACH_PORT_NULL);
    if (kr == MACH_RCV_TOO_LARGE || kr == MACH_RCV_INTERRUPTED) continue;
    if (kr != KERN_SUCCESS) return;
    bool complex = m.msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX;
    if (!complex || m.msg.body.msgh_descriptor_count != 1 || m.msg.header.msgh_size < sizeof(port_msg)) {
      mach_msg_destroy(&m.msg.header);
      continue;
    }
    fn(ctx, m.msg.header.msgh_id, m.msg.port.name, m.msg.value);
  }
}

static void destroy_receive_right(mach_port_t port) {
  mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
}

// ---- Server (producer) ----------------------------------------------

struct bw_frame_server {
  mach_port_t rcv;
  pthread_t thread;
  bw_subscribe_fn fn;
  void *ctx;
};

static void server_msg(void *ctx, mach_msg_id_t id, mach_port_t port, uint64_t nonce) {
  bw_frame_server *s = ctx;
  if (id != MSG_ID_SUBSCRIBE) {
    mach_port_deallocate(mach_task_self(), port);
    return;
  }
  s->fn(s->ctx, nonce, port); // callee owns the send right
}

static void *server_main(void *arg) {
  bw_frame_server *s = arg;
  pthread_setname_np("bowser.frames.server");
  receive_loop(s->rcv, server_msg, s);
  return NULL;
}

bw_frame_server *bw_frame_server_new(char name_out[BW_SERVICE_NAME_MAX], bw_subscribe_fn fn, void *ctx) {
  bw_frame_server *s = calloc(1, sizeof *s);
  s->fn = fn;
  s->ctx = ctx;
  snprintf(name_out, BW_SERVICE_NAME_MAX, "dev.libbowser.%d.%08x", getpid(), arc4random());
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  kern_return_t kr = bootstrap_check_in(bootstrap_port, name_out, &s->rcv);
#pragma clang diagnostic pop
  if (kr != KERN_SUCCESS) {
    fprintf(stderr, "bowser: bootstrap_check_in(%s) failed: %s\n", name_out, bootstrap_strerror(kr));
    free(s);
    return NULL;
  }
  pthread_create(&s->thread, NULL, server_main, s);
  return s;
}

void bw_frame_server_free(bw_frame_server *s) {
  if (!s) return;
  destroy_receive_right(s->rcv);
  pthread_join(s->thread, NULL);
  free(s);
}

bool bw_frame_send(mach_port_t host_port, IOSurfaceRef surface, uint64_t seq) {
  mach_port_t port = IOSurfaceCreateMachPort(surface);
  if (port == MACH_PORT_NULL) return false;
  kern_return_t kr = send_port(host_port, MSG_ID_FRAME, port, MACH_MSG_TYPE_MOVE_SEND, seq, 0);
  if (kr != KERN_SUCCESS) {
    // A timed-out send leaves the moved right with us.
    mach_port_deallocate(mach_task_self(), port);
    return false;
  }
  return true;
}

// ---- Client (host) --------------------------------------------------

struct bw_frame_client {
  mach_port_t rcv;
  pthread_t thread;
  bw_frame_fn fn;
  void *ctx;
};

static void client_msg(void *ctx, mach_msg_id_t id, mach_port_t port, uint64_t seq) {
  bw_frame_client *c = ctx;
  IOSurfaceRef surface = id == MSG_ID_FRAME ? IOSurfaceLookupFromMachPort(port) : NULL;
  mach_port_deallocate(mach_task_self(), port);
  if (surface) c->fn(c->ctx, surface, seq);
}

static void *client_main(void *arg) {
  bw_frame_client *c = arg;
  pthread_setname_np("bowser.frames.client");
  receive_loop(c->rcv, client_msg, c);
  return NULL;
}

bw_frame_client *bw_frame_client_new(const char *service, uint64_t nonce, bw_frame_fn fn, void *ctx) {
  mach_port_t server;
  if (bootstrap_look_up(bootstrap_port, service, &server) != KERN_SUCCESS) return NULL;

  bw_frame_client *c = calloc(1, sizeof *c);
  c->fn = fn;
  c->ctx = ctx;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &c->rcv);
  // A short queue: if the host falls behind, the producer drops frames
  // instead of piling them up.
  mach_port_limits_t limits = {.mpl_qlimit = 2};
  mach_port_set_attributes(mach_task_self(), c->rcv, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits,
                           MACH_PORT_LIMITS_INFO_COUNT);

  kern_return_t kr = send_port(server, MSG_ID_SUBSCRIBE, c->rcv, MACH_MSG_TYPE_MAKE_SEND, nonce, 1000);
  mach_port_deallocate(mach_task_self(), server);
  if (kr != KERN_SUCCESS) {
    destroy_receive_right(c->rcv);
    free(c);
    return NULL;
  }
  pthread_create(&c->thread, NULL, client_main, c);
  return c;
}

void bw_frame_client_free(bw_frame_client *c) {
  if (!c) return;
  destroy_receive_right(c->rcv);
  pthread_join(c->thread, NULL);
  free(c);
}
