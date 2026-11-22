#include "frames.h"

#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { MSG_ID_SUBSCRIBE = 0x626f7701, MSG_ID_FRAME = 0x626f7702, MSG_ID_QUIT = 0x626f7703 };

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

static kern_return_t send_port(mach_port_t dest, mach_msg_id_t id, mach_port_t port, uint64_t value,
                               mach_msg_timeout_t timeout) {
  port_msg m = {0};
  m.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
  m.header.msgh_size = sizeof m;
  m.header.msgh_remote_port = dest;
  m.header.msgh_id = id;
  m.body.msgh_descriptor_count = 1;
  m.port.name = port;
  m.port.disposition = MACH_MSG_TYPE_MOVE_SEND;
  m.port.type = MACH_MSG_PORT_DESCRIPTOR;
  m.value = value;
  // On failure the moved right stays with the caller, whether the kernel
  // refused the message outright or timed out after taking it.
  return mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, timeout,
                  MACH_PORT_NULL);
}

// Exactly the message we send: one send right, the expected id and size.
// Anyone who can look up the service can send anything else.
static bool well_formed(const port_msg *m, mach_msg_id_t want) {
  return m->header.msgh_id == want && m->header.msgh_size == sizeof *m &&
         (m->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) && m->body.msgh_descriptor_count == 1 &&
         m->port.type == MACH_MSG_PORT_DESCRIPTOR && m->port.disposition == MACH_MSG_TYPE_PORT_SEND &&
         MACH_PORT_VALID(m->port.name);
}

// Receive loop shared by both sides. Ends when *quit is set and any message
// wakes it, so it never depends on what becomes of the port's name.
typedef void (*port_fn)(void *ctx, mach_port_t port, uint64_t value);

static void receive_loop(mach_port_t rcv, mach_msg_id_t want, port_fn fn, void *ctx, atomic_bool *quit) {
  for (;;) {
    port_msg_rcv m;
    // The kernel destroys a message too large for the buffer.
    kern_return_t kr = mach_msg(&m.msg.header, MACH_RCV_MSG, 0, sizeof m, rcv, MACH_MSG_TIMEOUT_NONE,
                                MACH_PORT_NULL);
    if (kr == MACH_RCV_TOO_LARGE || kr == MACH_RCV_INTERRUPTED) continue;
    if (kr != KERN_SUCCESS) return;
    bool stop = atomic_load(quit);
    mach_port_t port = MACH_PORT_NULL;
    if (!stop && well_formed(&m.msg, want)) {
      port = m.msg.port.name;
      m.msg.port.name = MACH_PORT_NULL;
    }
    // Releases every right we didn't take: a reply port, a voucher, a descriptor.
    mach_msg_destroy(&m.msg.header);
    if (stop) return;
    if (port) fn(ctx, port, m.msg.value);
  }
}

static void stop_loop(mach_port_t rcv, atomic_bool *quit, pthread_t thread) {
  atomic_store(quit, true);
  mach_msg_header_t h = {0};
  h.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, 0, 0);
  h.msgh_size = sizeof h;
  h.msgh_remote_port = rcv;
  h.msgh_id = MSG_ID_QUIT;
  // Queue limits don't apply to send-once messages, so this always lands.
  mach_msg(&h, MACH_SEND_MSG, sizeof h, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
  pthread_join(thread, NULL);
  mach_port_mod_refs(mach_task_self(), rcv, MACH_PORT_RIGHT_RECEIVE, -1);
}

// ---- Server (producer) ----------------------------------------------

struct bw_frame_server {
  mach_port_t rcv;
  pthread_t thread;
  atomic_bool quit;
  bw_subscribe_fn fn;
  void *ctx;
};

static void server_msg(void *ctx, mach_port_t port, uint64_t nonce) {
  bw_frame_server *s = ctx;
  s->fn(s->ctx, nonce, port); // callee owns the send right
}

static void *server_main(void *arg) {
  bw_frame_server *s = arg;
  pthread_setname_np("bowser.frames.server");
  receive_loop(s->rcv, MSG_ID_SUBSCRIBE, server_msg, s, &s->quit);
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
  stop_loop(s->rcv, &s->quit, s->thread);
  free(s);
}

bool bw_frame_send(mach_port_t host_port, IOSurfaceRef surface, uint64_t seq) {
  mach_port_t port = IOSurfaceCreateMachPort(surface);
  if (port == MACH_PORT_NULL) return false;
  if (send_port(host_port, MSG_ID_FRAME, port, seq, 0) != KERN_SUCCESS) {
    mach_port_deallocate(mach_task_self(), port);
    return false;
  }
  return true;
}

// ---- Client (host) --------------------------------------------------

struct bw_frame_client {
  mach_port_t rcv;
  pthread_t thread;
  atomic_bool quit;
  bw_frame_fn fn;
  void *ctx;
};

static void client_msg(void *ctx, mach_port_t port, uint64_t seq) {
  bw_frame_client *c = ctx;
  IOSurfaceRef surface = IOSurfaceLookupFromMachPort(port);
  // The port right keeps the surface in use while the frame is in flight, and
  // lookup doesn't add a use. Take one before dropping the port, so the
  // producer never sees the frame as free while the host still holds it.
  if (surface) IOSurfaceIncrementUseCount(surface);
  mach_port_deallocate(mach_task_self(), port);
  if (surface) c->fn(c->ctx, surface, seq);
}

static void *client_main(void *arg) {
  bw_frame_client *c = arg;
  pthread_setname_np("bowser.frames.client");
  receive_loop(c->rcv, MSG_ID_FRAME, client_msg, c, &c->quit);
  return NULL;
}

bw_frame_client *bw_frame_client_new(const char *service, uint64_t nonce, mach_msg_timeout_t timeout_ms,
                                     bw_frame_fn fn, void *ctx) {
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
  mach_port_insert_right(mach_task_self(), c->rcv, c->rcv, MACH_MSG_TYPE_MAKE_SEND);

  kern_return_t kr = send_port(server, MSG_ID_SUBSCRIBE, c->rcv, nonce, timeout_ms);
  mach_port_deallocate(mach_task_self(), server);
  if (kr != KERN_SUCCESS) {
    mach_port_destruct(mach_task_self(), c->rcv, -1, 0); // the receive right and the unsent send right
    free(c);
    return NULL;
  }
  pthread_create(&c->thread, NULL, client_main, c);
  return c;
}

void bw_frame_client_free(bw_frame_client *c) {
  if (!c) return;
  stop_loop(c->rcv, &c->quit, c->thread);
  free(c);
}
