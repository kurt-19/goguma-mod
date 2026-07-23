#include "my_application.h"

int main(int argc, char** argv) {
  // Required for proper xdg-shell app ID with GTK3:
  // - https://gitlab.gnome.org/GNOME/gtk/-/commit/e1fd87728dd841cf1d71025983107765e395b152
  // - https://honk.sigxcpu.org/con/GTK__and_the_application_id.html
  g_set_prgname(APPLICATION_ID);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
