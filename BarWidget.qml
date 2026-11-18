import QtQuick
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui as Ui
import "Model.js" as Model

// Bar button plus the data side of the plugin. One collector process runs at a time; the panel
// (Panel.qml) only renders what this item holds.
Ui.BarWidget {
    id: root
    moduleName: Model.pluginId

    readonly property var panel: panelLoader.item
    readonly property var hostBar: bar
    readonly property var cfg: Model.config(settings)
    readonly property alias logs: logState
    property var inventory: ({})
    property var errors: ({})
    property var lastPoll: ({})
    property double lastUpdate: 0
    property string message: ""
    property bool messageUrgent: false
    // The running collector: { scope, generation, logToken, raw, exitCode, exited, streamed, timedOut }.
    property var job: null
    property var pendingLogs: null
    property int generation: 0
    property bool refreshing: false
    property string actionName: ""
    property var collectionSettings: null
    property var operation: ({
            op: "",
            label: "",
            running: false
        })
    property var operationJob: null
    // Set from handlers rather than bound: a binding over inventory and settings re-entered
    // itself while the host was assigning settings and logged a binding loop.
    property string tooltip: Model.displayName
    readonly property string actionsPath: decodeURIComponent(String(Qt.resolvedUrl("backend/actions.py")).replace(/^file:\/\//, ""))
    readonly property bool busy: job !== null
    readonly property bool opened: panelLoader.item ? panel.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panel.popoutSwitchClosing === true : false
    readonly property var counts: Model.counts(inventory, cfg)
    readonly property int serviceCount: counts.Localhost
    readonly property string errorText: Model.barError(errors)
    readonly property bool hasError: errorText !== ""
    readonly property var badgeAttention: cfg.statusBadge ? Model.attention(inventory, cfg) : ({
            unhealthy: 0,
            exposed: 0
        })
    readonly property string backendPath: decodeURIComponent(String(Qt.resolvedUrl("backend/collector.py")).replace(/^file:\/\//, ""))

    Commons.Translations {
        id: strings
        directory: Qt.resolvedUrl("i18n")
        onStringsChanged: Qt.callLater(root.updateTooltip)
    }

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
        if ((errors[scope] || "") === value)
            return;
        var updated = Object.assign({}, errors);
        updated[scope] = value;
        errors = updated;
    }

    function updateTooltip() {
        var reasons = [];
        if (badgeAttention.unhealthy)
            reasons.push(strings.tn("badge.unhealthy", badgeAttention.unhealthy).arg(badgeAttention.unhealthy));
        if (badgeAttention.exposed)
            reasons.push(strings.tn("badge.exposed", badgeAttention.exposed).arg(badgeAttention.exposed));
        tooltip = hasError ? Model.displayName + "\n" + errorText : Model.displayName + " · " + Model.summary(inventory, cfg, strings);
        if (reasons.length)
            tooltip += "\n" + reasons.join(" · ");
    }

    function notify(text, urgent) {
        message = text;
        messageUrgent = urgent === true;
        if (text)
            messageTimer.restart();
    }

    function poll() {
        if (job)
            return;
        var queued = pendingLogs;
        pendingLogs = null;
        if (queued && queued.token === logState.generation && opened && cfg.dockerEnabled) {
            start("logs", queued);
            return;
        }
        var scope = Model.nextScope(Date.now(), opened, cfg, lastPoll, false);
        if (scope)
            start(scope, null);
        else
            refreshing = false;
    }

    // Re-queries every scope, one after another, as soon as the worker is free.
    function refresh() {
        lastPoll = {};
        refreshing = true;
        poll();
    }

    function requestLogs(containerId, retain) {
        if (!opened || !cfg.dockerEnabled || !/^[a-f0-9]{64}$/.test(containerId))
            return;
        if (retain && logState.loading)
            return;
        pendingLogs = {
            id: containerId,
            token: logState.begin(containerId, retain)
        };
        poll();
    }

    function clearLogs() {
        pendingLogs = null;
        logState.clear();
    }

    function start(scope, request) {
        var args = ["python3", backendPath, scope];
        if (!cfg.dockerEnabled && ["ports", "docker", "assets", "logs"].indexOf(scope) >= 0)
            args.push("--no-docker");
        if (scope === "projects") {
            Model.lines(cfg.projectRoots).forEach(function (path) {
                args.push("--project-root=" + path);
            });
            args.push("--project-depth=" + cfg.projectDepth);
        }
        if (scope === "tools")
            Model.customLines(cfg.customTools).forEach(function (line) {
                args.push("--custom-tool=" + line);
            });
        if (scope === "ports")
            cfg.sqliteFiles.split("\n").filter(function (path) {
                return path.trim();
            }).forEach(function (path) {
                args.push("--sqlite-file=" + path.trim());
            });
        if (scope === "logs")
            args.push("--container-id=" + request.id);
        job = {
            scope: scope,
            generation: generation,
            logToken: scope === "logs" ? request.token : 0,
            raw: undefined,
            exitCode: -1,
            exited: false,
            streamed: false,
            timedOut: false
        };
        if (!request)
            lastPoll = Object.assign({}, lastPoll, {
                [scope]: Date.now()
            });
        worker.command = args;
        watchdog.interval = scope === "projects" ? 25000 : 15000;
        watchdog.restart();
        worker.running = true;
    }

    // Process exit and the end of its stdout arrive in no guaranteed order; a job is settled once
    // both are in, so a result is never decoded against the scope of the next request.
    function finish() {
        var done = job;
        if (!done)
            return;
        job = null;
        watchdog.stop();
        forceStop.stop();
        drain.stop();
        var outcome = Model.outcome(done.scope, done.raw, done.exitCode, done.timedOut);
        if (Model.current(done, generation, logState.generation)) {
            if (done.scope === "logs") {
                if (outcome.result)
                    logState.accept(done.logToken, outcome.result);
                else
                    logState.fail(done.logToken, outcome.error);
            } else {
                if (outcome.result)
                    inventory = Model.absorb(inventory, outcome.result.data);
                setError(done.scope, outcome.error);
                if (done.scope === "ports" && outcome.result && outcome.result.ok)
                    lastUpdate = Date.now();
            }
        }
        Qt.callLater(poll);
    }

    function saveSettings(values) {
        var problems = Model.validateSettings(values, strings);
        if (problems.length) {
            notify(problems.join("\n"), true);
            return false;
        }
        if (!bar || !hostBar.shell || typeof hostBar.shell.updateEntryInline !== "function") {
            notify(strings.t("message.settingsUnsupported"), true);
            return false;
        }
        var entry = Object.assign({}, root.settings, {
            settingsVersion: 2,
            visibleTabs: cfg.visibleTabs
        }, values, {
            id: moduleName
        });
        if (JSON.stringify(entry) === JSON.stringify(root.settings))
            return true;
        if (hostBar.shell.updateEntryInline(moduleName, entry) === false) {
            notify(strings.t("message.settingsFailed"), true);
            return false;
        }
        root.settings = entry;
        notify(strings.t("message.settingsSaved"), false);
        return true;
    }

    function run(name, command) {
        if (action.running)
            return;
        actionName = name;
        action.command = command;
        actionWatchdog.restart();
        action.running = true;
    }

    function runOperation(op, view, context) {
        if (operation.running)
            return false;
        if (["start", "stop", "restart", "terminate", "docker-start", "docker-stop", "docker-restart", "compose-start", "compose-stop", "compose-restart", "docker-compose-start", "docker-compose-stop", "docker-compose-restart", "process-terminate"].indexOf(op) >= 0 && !Model.canManage(view, cfg))
            return false;
        var args = Model.actionArgs(op, view, cfg, context);
        if (!args) {
            notify(strings.t("message.invalidOperation"), true);
            return false;
        }
        var titles = {
            "docker-start": strings.t("progress.start"),
            "docker-stop": strings.t("progress.stop"),
            "docker-restart": strings.t("progress.restart"),
            "docker-compose-start": strings.t("progress.start"),
            "docker-compose-stop": strings.t("progress.stop"),
            "docker-compose-restart": strings.t("progress.restart"),
            "process-terminate": strings.t("progress.stop"),
            "open-terminal": strings.t("progress.terminal"),
            "open-editor": strings.t("progress.editor"),
            "open-files": strings.t("progress.files"),
            "launch-tool": strings.t("progress.launch")
        };
        operation = {
            op: args[0],
            label: (titles[args[0]] || strings.t("progress.running")).arg(view.title || Model.rawRow(view).name || strings.t("progress.project")),
            running: true
        };
        operationJob = {
            op: args[0],
            raw: undefined,
            exitCode: -1,
            exited: false,
            streamed: false,
            timedOut: false
        };
        operationProcess.command = ["python3", actionsPath].concat(args);
        operationWatchdog.interval = args[0].startsWith("docker-compose-") ? 125000 : 45000;
        operationWatchdog.restart();
        operationProcess.running = true;
        return true;
    }

    function finishOperation() {
        var done = operationJob;
        if (!done)
            return;
        operationJob = null;
        operationWatchdog.stop();
        operationForceStop.stop();
        operationDrain.stop();
        operation = {
            op: done.op,
            label: "",
            running: false
        };
        var result;
        try {
            if (done.timedOut)
                throw new Error("Operation timed out.");
            result = Model.decodeAction(done.raw);
            if (result.action !== done.op)
                throw new Error("Mismatched action response.");
            if (!result.ok || done.exitCode !== 0)
                throw new Error(result.errors.join("\n") || "Operation failed (exit " + done.exitCode + ").");
            const labels = {
                "docker-start": strings.t("message.containerStarted"),
                "docker-stop": strings.t("message.containerStopped"),
                "docker-restart": strings.t("message.containerRestarted"),
                "docker-compose-start": strings.t("message.composeStarted"),
                "docker-compose-stop": strings.t("message.composeStopped"),
                "docker-compose-restart": strings.t("message.composeRestarted"),
                "open-terminal": strings.t("message.terminalOpened"),
                "open-editor": strings.t("message.editorOpened"),
                "open-files": strings.t("message.filesOpened"),
                "launch-tool": strings.t("message.toolLaunched")
            };
            notify(done.op === "process-terminate" ? result.data.result === "signaled" ? strings.t("message.processSignaled") : result.data.result === "already-exited" ? strings.t("message.processExited") : strings.t("message.processTerminated") : labels[done.op] || strings.t("message.completed"), false);
        } catch (error) {
            notify(strings.t("message.operationFailed").arg(error.message), true);
        }
        if (done.op.indexOf("docker-") === 0)
            lastPoll = Object.assign({}, lastPoll, {
                ports: 0,
                docker: 0,
                assets: 0
            });
        else if (done.op === "process-terminate")
            lastPoll = Object.assign({}, lastPoll, {
                ports: 0
            });
        Qt.callLater(poll);
    }

    function copyText(value) {
        if (value)
            run("Copy", ["wl-copy", "--type", "text/plain", "--", value]);
    }

    function openUrl(row, scheme) {
        var target = Model.url(row, scheme);
        if (target)
            run("Open", ["xdg-open", target]);
    }

    onBarChanged: injectPanel()
    onSettingsChanged: {
        // Runs while `cfg` may still be unevaluated, so derive the new configuration here.
        var next = Model.config(settings);
        var collecting = {
            dockerEnabled: next.dockerEnabled,
            sqliteFiles: next.sqliteFiles,
            projectRoots: next.projectRoots,
            projectDepth: next.projectDepth,
            customTools: next.customTools
        };
        var changed = JSON.stringify(collectionSettings) !== JSON.stringify(collecting);
        collectionSettings = collecting;
        if (changed) {
            generation++;
            clearLogs();
            lastPoll = {};
            Qt.callLater(poll);
        }
        if (!Model.lines(next.projectRoots).length) {
            inventory = Model.merge(inventory, {
                projects: [],
                skipped: 0
            });
            setError("projects", "");
        }
        if (!next.dockerEnabled) {
            inventory = Model.absorb(inventory, {
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
    onInventoryChanged: Qt.callLater(updateTooltip)
    onCfgChanged: Qt.callLater(updateTooltip)
    onErrorTextChanged: Qt.callLater(updateTooltip)
    Component.onCompleted: {
        Qt.callLater(updateTooltip);
        Qt.callLater(poll);
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    LogState {
        id: logState
    }

    Timer {
        interval: root.opened ? 1000 : 5000
        running: true
        repeat: true
        onTriggered: root.poll()
    }
    Timer {
        id: messageTimer
        interval: 4000
        onTriggered: root.message = ""
    }
    Timer {
        id: watchdog
        interval: 15000
        onTriggered: {
            if (!root.job)
                return;
            root.job.timedOut = true;
            if (worker.running) {
                worker.running = false;
                forceStop.restart();
            } else {
                root.finish();
            }
        }
    }
    Timer {
        id: forceStop
        interval: 1000
        onTriggered: {
            if (worker.running)
                worker.signal(9);
            else
                root.finish();
        }
    }
    // A process that never started produces an exit without a stream end.
    Timer {
        id: drain
        interval: 300
        onTriggered: root.finish()
    }
    Process {
        id: worker
        objectName: "collector"
        stdout: StdioCollector {
            onStreamFinished: {
                if (!root.job)
                    return;
                root.job.raw = text;
                root.job.streamed = true;
                if (root.job.exited)
                    root.finish();
            }
        }
        stderr: StdioCollector {}
        // Quickshell clears `running` without an exit signal when the program cannot start.
        onRunningChanged: {
            if (!running && root.job && !root.job.exited)
                drain.restart();
        }
        onExited: function (exitCode, exitStatus) {
            if (!root.job)
                return;
            root.job.exitCode = exitCode;
            root.job.exited = true;
            if (root.job.streamed)
                root.finish();
            else
                drain.restart();
        }
    }
    Timer {
        id: actionWatchdog
        interval: 5000
        onTriggered: {
            if (action.running)
                action.signal(9);
            root.notify((root.actionName === "Copy" ? strings.t("message.copyTimeout") : strings.t("message.openTimeout")), true);
        }
    }
    Process {
        id: action
        objectName: "action"
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: function (exitCode, exitStatus) {
            actionWatchdog.stop();
            if (exitCode === 0)
                root.notify(root.actionName === "Copy" ? strings.t("message.copied") : strings.t("message.browserOpened"), false);
            else
                root.notify(root.actionName === "Copy" ? strings.t("message.copyFailed") : strings.t("message.openFailed"), true);
        }
    }
    Timer {
        id: operationWatchdog
        objectName: "operationWatchdog"
        interval: 45000
        onTriggered: {
            if (!root.operationJob)
                return;
            root.operationJob.timedOut = true;
            if (operationProcess.running) {
                operationProcess.signal(15);
                operationForceStop.restart();
            } else
                root.finishOperation();
        }
    }
    Timer {
        id: operationForceStop
        objectName: "operationForceStop"
        interval: 1000
        onTriggered: {
            if (operationProcess.running)
                operationProcess.signal(9);
            else
                root.finishOperation();
        }
    }
    Timer {
        id: operationDrain
        interval: 300
        onTriggered: root.finishOperation()
    }
    Process {
        id: operationProcess
        objectName: "operation"
        stdout: StdioCollector {
            onStreamFinished: {
                if (!root.operationJob)
                    return;
                root.operationJob.raw = text;
                root.operationJob.streamed = true;
                if (root.operationJob.exited)
                    root.finishOperation();
            }
        }
        stderr: StdioCollector {}
        onRunningChanged: if (!running && root.operationJob && !root.operationJob.exited)
            operationDrain.restart()
        onExited: function (exitCode, exitStatus) {
            if (!root.operationJob)
                return;
            root.operationJob.exitCode = exitCode;
            root.operationJob.exited = true;
            if (root.operationJob.streamed)
                root.finishOperation();
            else
                operationDrain.restart();
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
    Ui.BarIconButton {
        id: button
        objectName: "statusIcon"
        anchors.fill: parent
        bar: root.bar
        text: Model.icon
        active: root.hasError || root.badgeAttention.unhealthy > 0 || root.badgeAttention.exposed > 0
        tooltipText: root.tooltip
        onPressed: function (buttonCode) {
            if (buttonCode === Qt.LeftButton)
                root.toggle();
            else
                root.refresh();
        }
    }
}
