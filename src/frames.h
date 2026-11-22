// Frame channel for the IOSURFACE transport. The producer checks in a Mach
// service; a host subscribes with a send right to its own port; the producer
// then sends one IOSurface mach port per frame.
#ifndef BOWSER_FRAMES_H
#define BOWSER_FRAMES_H

#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>

#define BW_SERVICE_NAME_MAX 128

typedef struct bw_frame_server bw_frame_server;
typedef void (*bw_subscribe_fn)(void *ctx, uint64_t nonce, mach_port_t host_port);

bw_frame_server *bw_frame_server_new(char name_out[BW_SERVICE_NAME_MAX], bw_subscribe_fn, void *ctx);
void bw_frame_server_free(bw_frame_server *);
// Never blocks. Returns false if the host's queue is full or the host is gone.
bool bw_frame_send(mach_port_t host_port, IOSurfaceRef, uint64_t seq);

typedef struct bw_frame_client bw_frame_client;
// Called on the client's receive thread. The callee owns the IOSurfaceRef.
typedef void (*bw_frame_fn)(void *ctx, IOSurfaceRef, uint64_t seq);

bw_frame_client *bw_frame_client_new(const char *service, uint64_t nonce, bw_frame_fn, void *ctx);
void bw_frame_client_free(bw_frame_client *);

#endif
