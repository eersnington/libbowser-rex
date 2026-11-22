#import "link.h"

#include <errno.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct {
  uint8_t *data;
  size_t len;
  uint32_t kind; // bw_latest_wins_kind
} tx_frame;

@interface BWLink : NSObject {
 @public
  int fd;
  dispatch_queue_t queue;
  dispatch_source_t readSource, writeSource;
  void (^reader)(void);
  // Only touched on the queue.
  bw_buf rx;
  bool eof, corrupt;
  // Guarded by lock, the innermost lock. Nothing calls out while holding it.
  os_unfair_lock lock;
  tx_frame *tx; // queued frames are tx[txHead, txEnd)
  size_t txHead, txEnd, txCap;
  size_t txOff; // bytes of tx[txHead] already written
  size_t txBytes;
  bowser_result_e failed; // the link failed on our side: a stall or a write error
  bool paused;            // readSource is suspended, or inactive before bw_link_start
  bool writing;           // writeSource is resumed
  bool readStopped, writeStopped, finishing;
}
@end

static void stop_reading_locked(BWLink *l) {
  if (l->readStopped) return;
  l->readStopped = true;
  dispatch_source_cancel(l->readSource);
  // A suspended source never runs its cancel handler, and releasing one crashes.
  if (l->paused) {
    l->paused = false;
    dispatch_resume(l->readSource);
  }
}

static void stop_writing_locked(BWLink *l) {
  if (l->writeStopped) return;
  l->writeStopped = true;
  dispatch_source_cancel(l->writeSource);
  if (!l->writing) {
    l->writing = true;
    dispatch_resume(l->writeSource);
  }
}

static void drop_tx_locked(BWLink *l) {
  for (size_t i = l->txHead; i < l->txEnd; i++) free(l->tx[i].data);
  l->txHead = l->txEnd = l->txOff = l->txBytes = 0;
}

// The peer gets EOF, and so does our read source, so the owner's reader sees
// the link end.
static void fail_locked(BWLink *l, bowser_result_e why) {
  if (l->failed) return;
  l->failed = why;
  drop_tx_locked(l);
  shutdown(l->fd, SHUT_RDWR);
}

static void push_locked(BWLink *l, uint8_t *data, size_t len, uint32_t kind) {
  if (kind) {
    // Drop the newest queued frame of this kind if only other latest-wins
    // frames follow it. The peer still sees a subsequence of what was sent,
    // minus states that a newer one of the same kind replaced.
    size_t first = l->txHead + (l->txOff ? 1 : 0); // a partly written frame stays
    for (size_t i = l->txEnd; i > first; i--) {
      tx_frame *f = &l->tx[i - 1];
      if (!f->kind) break;
      if (f->kind != kind) continue;
      l->txBytes -= f->len;
      free(f->data);
      memmove(f, f + 1, (l->txEnd - i) * sizeof *f);
      l->txEnd--;
      break;
    }
  }
  if (l->txEnd == l->txCap) {
    if (l->txHead > l->txCap / 2) {
      memmove(l->tx, l->tx + l->txHead, (l->txEnd - l->txHead) * sizeof *l->tx);
      l->txEnd -= l->txHead;
      l->txHead = 0;
    } else {
      l->txCap = l->txCap ? l->txCap * 2 : 64;
      l->tx = realloc(l->tx, l->txCap * sizeof *l->tx);
    }
  }
  l->tx[l->txEnd++] = (tx_frame){data, len, kind};
  l->txBytes += len;
}

static void link_read(BWLink *l) {
  os_unfair_lock_lock(&l->lock);
  bool skip = l->readStopped || l->paused;
  os_unfair_lock_unlock(&l->lock);
  if (skip) return;
  if (!l->eof && !bw_recv_some(l->fd, &l->rx)) l->eof = true;
  l->reader();
}

static void link_write(BWLink *l) {
  os_unfair_lock_lock(&l->lock);
  if (l->writeStopped) {
    os_unfair_lock_unlock(&l->lock);
    return;
  }
  while (l->txHead < l->txEnd) {
    tx_frame *f = &l->tx[l->txHead];
    ssize_t w = write(l->fd, f->data + l->txOff, f->len - l->txOff);
    if (w < 0) {
      if (errno == EINTR) continue;
      if (errno != EAGAIN) fail_locked(l, BOWSER_ERR_DISCONNECTED);
      break;
    }
    l->txOff += (size_t)w;
    if (l->txOff < f->len) continue;
    l->txBytes -= f->len;
    free(f->data);
    l->txOff = 0;
    if (++l->txHead == l->txEnd) l->txHead = l->txEnd = 0;
  }
  bool drained = l->txHead == l->txEnd;
  bool done = drained && l->finishing;
  if (drained && !done) {
    // A write source fires whenever the socket has room, so it runs only
    // while there is something to send.
    l->writing = false;
    dispatch_suspend(l->writeSource);
  }
  os_unfair_lock_unlock(&l->lock);
  if (done) bw_link_close(l);
}

@implementation BWLink
- (void)dealloc {
  bw_link_close(self);
  free(tx);
  bw_buf_free(&rx);
}
@end

BWLink *bw_link_new(int fd, dispatch_queue_t queue, bw_buf *rx, void (^reader)(void)) {
  BWLink *l = [BWLink new];
  l->fd = fd;
  l->queue = queue;
  l->reader = reader;
  l->lock = OS_UNFAIR_LOCK_INIT;
  l->paused = true;
  if (rx) {
    l->rx = *rx;
    *rx = (bw_buf){0};
  }
  l->readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
  l->writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, queue);
  __weak BWLink *weak = l;
  dispatch_source_set_event_handler(l->readSource, ^{
    BWLink *link = weak;
    if (link) link_read(link);
  });
  dispatch_source_set_event_handler(l->writeSource, ^{
    BWLink *link = weak;
    if (link) link_write(link);
  });
  // Close the socket only when neither source can touch it.
  __block int sources = 2;
  dispatch_block_t cancelled = ^{
    if (--sources == 0) close(fd);
  };
  dispatch_source_set_cancel_handler(l->readSource, cancelled);
  dispatch_source_set_cancel_handler(l->writeSource, cancelled);
  return l;
}

// The write source stays inactive until there is something to send.
void bw_link_start(BWLink *l) { bw_link_resume(l); }

bool bw_link_next(BWLink *l, uint16_t *type, bw_buf *payload) {
  if (l->corrupt) return false;
  bool bad;
  if (bw_next_frame(&l->rx, type, payload, &bad)) return true;
  if (bad) l->corrupt = true;
  return false;
}

bool bw_link_ended(BWLink *l, bowser_result_e *why) {
  os_unfair_lock_lock(&l->lock);
  bowser_result_e failed = l->failed;
  os_unfair_lock_unlock(&l->lock);
  if (!failed && !l->eof && !l->corrupt) return false;
  *why = failed ? failed : BOWSER_ERR_DISCONNECTED;
  return true;
}

void bw_link_pause(BWLink *l) {
  os_unfair_lock_lock(&l->lock);
  if (!l->readStopped && !l->paused) {
    l->paused = true;
    dispatch_suspend(l->readSource);
  }
  os_unfair_lock_unlock(&l->lock);
}

void bw_link_resume(BWLink *l) {
  os_unfair_lock_lock(&l->lock);
  bool resumed = l->paused;
  if (resumed) {
    l->paused = false;
    dispatch_resume(l->readSource);
  }
  os_unfair_lock_unlock(&l->lock);
  // Frames may already sit in rx, and the source doesn't fire for those.
  if (resumed) dispatch_async(l->queue, ^{ link_read(l); });
}

bowser_result_e bw_link_send(BWLink *l, uint16_t type, const bw_buf *payload) {
  bw_buf empty = {0};
  if (!payload) payload = &empty;
  if (payload->len > BW_MAX_FRAME)
    return bw_fail(BOWSER_ERR_INVALID, "message is %zu bytes; the limit is %u", payload->len, BW_MAX_FRAME);
  bw_buf frame = {0};
  bw_put_frame(&frame, type, payload);
  uint32_t kind = bw_latest_wins_kind(type, payload);

  os_unfair_lock_lock(&l->lock);
  bowser_result_e rc = l->failed;
  if (!rc && (l->writeStopped || l->finishing)) rc = BOWSER_ERR_DISCONNECTED;
  if (!rc) {
    push_locked(l, frame.data, frame.len, kind);
    frame.data = NULL;
    if (l->txBytes > BW_MAX_QUEUED) {
      fail_locked(l, BOWSER_ERR_STALLED);
      rc = BOWSER_ERR_STALLED;
    } else if (!l->writing) {
      l->writing = true;
      dispatch_resume(l->writeSource);
    }
  }
  os_unfair_lock_unlock(&l->lock);
  free(frame.data);
  if (rc == BOWSER_ERR_STALLED) return bw_fail(rc, "the other side stopped reading");
  if (rc) return bw_fail(rc, "not connected");
  return BOWSER_OK;
}

void bw_link_finish(BWLink *l) {
  os_unfair_lock_lock(&l->lock);
  bool already = l->finishing || l->writeStopped;
  l->finishing = true;
  stop_reading_locked(l);
  bool drained = l->txHead == l->txEnd;
  os_unfair_lock_unlock(&l->lock);
  if (already) return;
  if (drained) {
    bw_link_close(l);
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), l->queue, ^{ bw_link_close(l); });
}

void bw_link_close(BWLink *l) {
  if (!l) return;
  os_unfair_lock_lock(&l->lock);
  stop_reading_locked(l);
  stop_writing_locked(l);
  drop_tx_locked(l);
  os_unfair_lock_unlock(&l->lock);
}
