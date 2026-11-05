# Local anatomy viewer

The login service runs the viewer in the sibling EML checkout at <http://127.0.0.1:8765/>. It uses that checkout’s own catalog, compiler, and anatomy. It starts at user login, restarts if the server exits, and serves only on this Mac. It is available while the Mac is awake and the user is logged in.

From the wrapper root, prepare the EML checkout once if needed, then install:

```sh
python3 -m venv ../eml/.venv
../eml/.venv/bin/python -m pip install -r ../eml/requirements.txt
python3 Revision/Tools/viewer-service/service.py install
python3 Revision/Tools/viewer-service/service.py status
```

If a manually started viewer from the same checkout owns the port, use `install --adopt` to transfer it to launchd. To use another EML checkout, pass `install --eml /path/to/eml`. Reinstall after moving the checkout. The service reads exercise and vocabulary edits on request. After editing the Python compiler or server, run `launchctl kickstart -k gui/$(id -u)/com.agrim.eml-anatomy-viewer`. View service logs in `~/Library/Logs/com.agrim.eml-anatomy-viewer/`. Remove the login service with `python3 Revision/Tools/viewer-service/service.py uninstall`.
