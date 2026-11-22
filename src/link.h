// One framed control socket, driven on a serial dispatch queue.
//
// A read source fills a buffer and calls the owner's reader on the queue; the
// reader pops frames. bw_link_send only queues a frame; a write source drains
// the queue on the link's queue. So no caller writes to the socket, blocks on
// a slow peer, or holds a lock across a call into the other process.
#ifndef BOWSER_LINK_H
#define BOWSER_LINK_H

#import <Foundation/Foundation.h>

#include "internal.h"

@class BWLink;

// Takes ownership of fd, which must be nonblocking, and of the bytes in rx
// (handshake leftovers). The reader runs on queue after bw_link_start: once at
// the start, then whenever data arrives.
BWLink *bw_link_new(int fd, dispatch_queue_t queue, bw_buf *rx, void (^reader)(void));
void bw_link_start(BWLink *);

// In the reader: pop one complete frame. The caller frees the payload.
bool bw_link_next(BWLink *, uint16_t *type, bw_buf *payload);
// In the reader, once no frame is left: whether the link is over, and why.
// The owner must then close it.
bool bw_link_ended(BWLink *, bowser_result_e *why);
// In the reader: stop reading, and calling the reader, until bw_link_resume.
void bw_link_pause(BWLink *);
void bw_link_resume(BWLink *); // any thread

// Any thread; never blocks. See "Sending" in bowser.h.
bowser_result_e bw_link_send(BWLink *, uint16_t type, const bw_buf *payload);
// Any thread. Stop reading now, write what's queued, then close. A peer that
// doesn't read gets 1 s.
void bw_link_finish(BWLink *);
// Any thread. Stop now and drop what's queued.
void bw_link_close(BWLink *);

#endif
