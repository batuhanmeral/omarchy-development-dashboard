import QtQuick
import Quickshell.Io
import qs.Ui as Ui
import "Model.js" as Model

Ui.BarWidget {
    id: root
    readonly property var panel: panelLoader.item
    readonly property var hostBar: bar
    moduleName: "io.github.batuhanmeral.devports"

    readonly property var cfg: Model.config(settings)
    property var inventory: ({})
    property var errors: ({})
    property var lastPoll: ({})
    property var lastSuccess: ({})
    property string message: ""
    readonly property string logText: logs.text
    property int requestLogToken: 0
    property bool busy: false
    property bool timedOut: false
    property bool received: false
    property string requestScope: ""
    property int generation: 0
    property int requestGeneration: 0
    property string actionName: ""
    readonly property bool opened: panelLoader.item ? panel.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panel.popoutSwitchClosing === true : false
    readonly property int serviceCount: Model.rows(inventory, "Localhost", "", "all", cfg).length
    readonly property bool hasError: Object.keys(errors).some(function (key) {
        return !!root.errors[key];
    })
    readonly property string errorText: Object.keys(errors).filter(function (key) {
        return !!root.errors[key];
    }).map(function (key) {
        return key + ": " + root.errors[key];
    }).join("\n")
    readonly property string backendPath: decodeURIComponent(String(Qt.resolvedUrl("backend/collector.py")).replace(/^file:\/\//, ""))

    function open() {
        if (panelLoader.item)
            panel.open();
    }
    function close() {
        if (panelLoader.item)
            panel.close();
    }
    function toggle() {
        if (panelLoader.item)
            panel.toggle();
    }
    function closeForPopoutSwitch() {
        if (panelLoader.item)
            panel.closeForPopoutSwitch();
    }

    function injectPanel() {
        if (!panelLoader.item)
            return;
        panel.bar = root.bar;
        panel.anchorItem = button;
        panel.hostWidget = root;
    }

    function setError(scope, value) {
        var updated = Object.assign({}, errors);
        updated[scope] = value;
        errors = updated;
    }

    function poll() {
        var scope = Model.nextScope(Date.now(), opened, cfg, lastPoll, busy || worker.running);
        if (scope)
            request(scope, "");
    }

    function refresh() {
        if (busy || worker.running) {
            message = "A refresh is already running.";
            return;
        }
        lastPoll = {};
        message = "";
        poll();
    }

    function clearLogs() {
        logs.clear();
        setError("logs", "");
    }

    function currentRequest() {
        return requestGeneration === generation && (requestScope !== "logs" || requestLogToken === logs.generation);
    }

    function request(scope, containerId) {
        if (busy || worker.running)
            return;
        if (scope === "logs" && (!opened || !cfg.dockerEnabled || !/^[a-f0-9]{64}$/.test(containerId)))
            return;
        var args = ["python3", backendPath, scope];
        if (!cfg.dockerEnabled)
            args.push("--no-docker");
        if (scope === "ports")
            cfg.sqliteFiles.split("\n").filter(function (path) {
                return path.trim();
            }).forEach(function (path) {
                args.push("--sqlite-file", path.trim());
            });
        if (scope === "logs") {
            args.push("--container-id", containerId);
            requestLogToken = logs.begin(containerId);
        }
        requestScope = scope;
        requestGeneration = generation;
        timedOut = false;
        received = false;
        busy = true;
        lastPoll = Object.assign({}, lastPoll, {
            [scope]: Date.now()
        });
        worker.command = args;
        watchdog.restart();
        worker.running = true;
    }

    function consume(raw) {
        received = true;
        if (timedOut || !currentRequest())
            return;
        try {
            let result = Model.decode(raw, requestScope);
            if (requestScope === "logs") {
                if (!logs.accept(requestLogToken, result))
                    return;
            } else {
                inventory = Model.merge(inventory, result.data);
            }
            setError(requestScope, result.errors.join("\n"));
            if (result.ok)
                lastSuccess = Object.assign({}, lastSuccess, {
                    [requestScope]: Date.now()
                });
        } catch (error) {
            setError(requestScope, "Invalid collector response: " + error.message);
        }
    }

    function saveSettings(values) {
        var problems = Model.validateSettings(values);
        if (problems.length) {
            message = problems.join("\n");
            return false;
        }
        if (!bar || !hostBar.shell || typeof hostBar.shell.updateEntryInline !== "function") {
            message = "This bar does not expose persistent plugin settings.";
            return false;
        }
        var entry = Object.assign({}, root.settings, values, {
            id: moduleName
        });
        if (JSON.stringify(entry) === JSON.stringify(root.settings)) {
            message = "Settings unchanged.";
            return true;
        }
        if (hostBar.shell.updateEntryInline(moduleName, entry) === false) {
            message = "Settings could not be saved by the shell.";
            return false;
        }
        root.settings = entry;
        message = "Settings saved.";
        return true;
    }

    function copyText(value) {
        if (!value || action.running)
            return;
        actionName = "Copy";
        action.command = ["wl-copy", "--type", "text/plain", "--", value];
        actionWatchdog.restart();
        action.running = true;
    }

    function openUrl(row, scheme) {
        var target = Model.url(row, scheme);
        if (!target || action.running)
            return;
        actionName = "Open URL";
        action.command = ["xdg-open", target];
        actionWatchdog.restart();
        action.running = true;
    }

    onBarChanged: injectPanel()
    onSettingsChanged: {
        generation++;
        clearLogs();
        lastPoll = {};
        if (!cfg.dockerEnabled) {
            inventory = Model.merge(inventory, {
                containers: [],
                images: [],
                volumes: [],
                dockerStatus: "disabled"
            });
            setError("docker", "");
            setError("assets", "");
        }
        injectPanel();
    }
    onOpenedChanged: {
        if (opened) {
            lastPoll = Object.assign({}, lastPoll, {
                ports: 0
            });
            poll();
        } else {
            clearLogs();
        }
    }
    Component.onCompleted: Qt.callLater(poll)

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    LogState {
        id: logs
    }

    Timer {
        interval: root.opened ? 1000 : 5000
        running: true
        repeat: true
        onTriggered: root.poll()
    }
    Timer {
        id: watchdog
        interval: 15000
        onTriggered: {
            root.timedOut = true;
            if (root.currentRequest())
                root.setError(root.requestScope, "Collector timeout; previous data may be stale.");
            if (worker.running) {
                worker.running = false;
                forceStop.restart();
            } else
                root.busy = false;
        }
    }
    Timer {
        id: forceStop
        interval: 1000
        onTriggered: {
            if (worker.running)
                worker.signal(9);
            else
                root.busy = false;
        }
    }
    Process {
        id: worker
        stdout: StdioCollector {
            onStreamFinished: root.consume(text)
        }
        stderr: StdioCollector {}
        onExited: function (exitCode, exitStatus) {
            watchdog.stop();
            forceStop.stop();
            if (!root.timedOut && root.currentRequest() && (!root.received || (exitCode !== 0 && !root.errors[root.requestScope])))
                root.setError(root.requestScope, "Collector failed (exit " + exitCode + ").");
            root.busy = false;
        }
    }
    Timer {
        id: actionWatchdog
        interval: 5000
        onTriggered: {
            if (action.running)
                action.signal(9);
            root.message = root.actionName + " timed out or could not start.";
        }
    }
    Process {
        id: action
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: function (exitCode, exitStatus) {
            actionWatchdog.stop();
            root.message = exitCode === 0 ? root.actionName + " completed." : root.actionName + " failed; check the required tool is available.";
        }
    }
    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }
    Ui.WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: ">_ " + (root.errors.ports ? "?" : root.serviceCount) + (root.hasError ? " !" : "")
        active: root.hasError
        tooltipText: "Development Ports · " + root.serviceCount + " endpoints" + (root.hasError ? "\n" + root.errorText : "")
        onPressed: function (buttonCode) {
            if (buttonCode === Qt.LeftButton)
                root.toggle();
            else if (buttonCode === Qt.RightButton)
                root.refresh();
        }
    }
}
