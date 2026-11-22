# dev.libbowser Rex block plugin

1. Start an isolated dev server with the plugin (builds `plugin/`, all state goes in `rex/dev/`): `rex/dev-server.sh`
2. Make a session with a browser block: `rex/rx api call session.create '{"initial_windows":[{"layout":{"block":{"flavor":"dev.libbowser.browser","label":"web","options":{"transport":"iosurface"}}}}]}'`
3. Get a single-use ticket and attach a host: `BOWSER_SPACE=3 build/bowser-host "$(rex/rx block call -b web ticket | jq -r .ticket)"`
4. Watch `host_attached`, `host_detached` and `producer_exited`: `rex/rx events -s <session> --json`. Plugin log: `rex/dev/logs/plugin.log`.
5. Set `BOWSER_PRODUCER` to use another producer, for example bowser-cef. It gets `--transport T --tickets 16 [--url U]`. See `PROTOCOL.md` for the wire protocol.
