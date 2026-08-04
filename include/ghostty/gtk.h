#ifndef GHOSTTY_GTK_H
#define GHOSTTY_GTK_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ghostty_gtk_embed_runtime_s ghostty_gtk_embed_runtime_t;
typedef struct _GtkWidget GtkWidget;

typedef enum {
    GHOSTTY_GTK_EMBED_ASYNC_DEFAULT = 0,
    GHOSTTY_GTK_EMBED_ASYNC_EPOLL = 1,
    GHOSTTY_GTK_EMBED_ASYNC_IO_URING = 2,
} ghostty_gtk_embed_async_backend_t;

// Every function in this API must be called from the GTK main thread.

// Creates the Ghostty core used by embedded GTK terminal surfaces. A process
// may create one runtime; all later constructor calls return null, including
// after it is freed, because Ghostty process-global state is not restartable.
// The host must destroy every returned widget and drain pending GLib
// finalization before freeing the runtime. Null, stale, and foreign runtime
// handles are rejected by the operations below. Create the runtime before
// calling gtk_init() or constructing other GTK objects; runtime initialization
// owns the required process signal and GTK setup order.
ghostty_gtk_embed_runtime_t *ghostty_gtk_embed_runtime_new(void);
// Selects the IO event backend before Ghostty creates any event loops. Returns
// null when the requested backend is unavailable on the current platform.
ghostty_gtk_embed_runtime_t *ghostty_gtk_embed_runtime_new_with_async_backend(
    ghostty_gtk_embed_async_backend_t backend
);
void ghostty_gtk_embed_runtime_free(ghostty_gtk_embed_runtime_t *runtime);

// Drives Ghostty's application mailbox from the host's GTK main loop.
// Returns false if the runtime is null, stale, or a core tick fails.
bool ghostty_gtk_embed_runtime_tick(ghostty_gtk_embed_runtime_t *runtime);

// Returns a new GhosttySurface as a GtkWidget. The command and title are
// copied; either may be null. Normal GTK container ownership rules apply.
GtkWidget *ghostty_gtk_embed_surface_new(
    ghostty_gtk_embed_runtime_t *runtime,
    const char *command,
    const char *title
);

/**
 * Close the native terminal state for a detached embedding surface. This is
 * also valid before the surface has initialized its terminal core.
 *
 * The caller retains its GtkWidget reference and must release it normally.
 * After this succeeds, no other ghostty_gtk_embed_surface_* operation is
 * valid for this widget. This must precede runtime destruction when GTK/GSK
 * may still retain the unparented widget internally.
 */
bool ghostty_gtk_embed_surface_close(GtkWidget *surface);

// Transfers keyboard focus to the terminal's internal input widget. Calling
// gtk_widget_grab_focus() on the returned composite widget is insufficient.
// Null and non-Ghostty widgets are ignored.
void ghostty_gtk_embed_surface_grab_focus(GtkWidget *surface);

// Sends UTF-8 text through the terminal input path. Returns false for a
// null/uninitialized surface, null text, or input error.
bool ghostty_gtk_embed_surface_send_text(
    GtkWidget *surface,
    const char *text
);

// Parses and invokes a Ghostty binding action on the terminal surface. The
// action bytes are borrowed for this call and do not need a trailing NUL.
// Returns false for an invalid/uninitialized surface, invalid bytes, an
// unknown action, or a terminal-side action failure.
bool ghostty_gtk_embed_surface_binding_action(
    GtkWidget *surface,
    const char *action,
    size_t action_len
);

// Starts an asynchronous paste from the standard GTK clipboard. Completion is
// reported by the surface's existing "clipboard-read" signal.
bool ghostty_gtk_embed_surface_request_paste(GtkWidget *surface);

#ifdef __cplusplus
}
#endif

#endif
