project('shelly-notifications', ['vala', 'c'],
  version : '1.0.0',
  meson_version : '>= 0.56.0',
)

add_project_arguments(['--pkg', 'posix'], language : 'vala')

deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('json-glib-1.0'),
]

sources = files(
  'src/main.vala',
  'src/tray_item.vala',
  'src/dbus_interfaces.vala',
  'src/dbus_menu.vala',
  'src/config_reader.vala',
  'src/update_service.vala',
  'src/notification_handler.vala',
  'src/app_runner.vala',
  'src/shelly_ui_receiver.vala',
  'src/next_notification.vala',
)

executable('shelly-notifications',
  sources,
  dependencies : deps,
  install : false,
)
