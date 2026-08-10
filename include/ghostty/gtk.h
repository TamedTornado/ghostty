#ifndef GHOSTTY_GTK_H
#define GHOSTTY_GTK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

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

typedef uint32_t ghostty_gtk_embed_text_extent_t;
#define GHOSTTY_GTK_EMBED_TEXT_VIEWPORT ((ghostty_gtk_embed_text_extent_t) 0)
#define GHOSTTY_GTK_EMBED_TEXT_SCREEN ((ghostty_gtk_embed_text_extent_t) 1)

typedef void (*ghostty_gtk_embed_text_callback_t)(
    const char *text,
    size_t text_len,
    void *userdata
);

typedef struct {
    size_t struct_size;
    const char *command;
    const char *title;
    const char *working_directory;
    const char *const *environment;
    size_t environment_count;
} ghostty_gtk_embed_surface_options_t;

typedef struct {
    double width;
    double height;
} ghostty_gtk_embed_cell_size_t;

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

// Returns a new GhosttySurface using versioned, copied construction options.
// struct_size must include fields through working_directory; appended fields
// are read only when struct_size includes them. String fields may be null.
// working_directory selects the child process directory without requiring the
// embedding host to synthesize a shell command. environment is a copied array
// of environment_count non-null KEY=VALUE strings (at most 128); it augments
// and overrides the child environment for this surface only.
GtkWidget *ghostty_gtk_embed_surface_new_with_options(
    ghostty_gtk_embed_runtime_t *runtime,
    const ghostty_gtk_embed_surface_options_t *options
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

// Returns the rendered terminal cell dimensions in logical pixels. The
// values reflect the surface's active font metrics and may change after
// configuration or scale changes. Returns false for invalid arguments or an
// uninitialized surface and leaves cell_size unchanged.
bool ghostty_gtk_embed_surface_cell_size(
    GtkWidget *surface,
    ghostty_gtk_embed_cell_size_t *cell_size
);

// Reads plain terminal text synchronously and invokes callback exactly once
// with bytes borrowed for the duration of the callback. SCREEN includes
// scrollback; VIEWPORT includes only the currently visible terminal rows.
// Returns false without invoking callback for invalid arguments, an
// uninitialized surface, or a terminal-side read failure.
bool ghostty_gtk_embed_surface_read_text(
    GtkWidget *surface,
    ghostty_gtk_embed_text_extent_t extent,
    ghostty_gtk_embed_text_callback_t callback,
    void *userdata
);

// Reads the current user selection synchronously and invokes callback exactly
// once with bytes borrowed for the duration of the callback. Returns false
// without invoking callback when there is no selection, arguments are invalid,
// the surface is uninitialized, or the terminal-side read fails.
bool ghostty_gtk_embed_surface_read_selection(
    GtkWidget *surface,
    ghostty_gtk_embed_text_callback_t callback,
    void *userdata
);

// Starts an asynchronous paste from the standard GTK clipboard. Completion is
// reported by the surface's existing "clipboard-read" signal.
bool ghostty_gtk_embed_surface_request_paste(GtkWidget *surface);

#ifdef __cplusplus
}
#endif

#endif
