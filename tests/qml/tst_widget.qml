import QtQuick
import QtTest
import "../.." as Plugin

// Loads the real BarWidget and Panel against headless stand-ins for Quickshell.Io and the Omarchy
// kit (tests/qml/imports). Collector runs are driven by hand through the Process stand-in.
TestCase {
    id: suite
    name: "DevelopmentPortsWidget"
    width: 520
    height: 720
    when: windowShown

    readonly property string cid: "a".repeat(64)

    QtObject {
        id: fakeBar
        property var saved: []
        property QtObject shell: QtObject {
            function updateEntryInline(id, entry) {
                fakeBar.saved = fakeBar.saved.concat([entry]);
                return true;
            }
        }
    }

    Component {
        id: widgetComponent
        Plugin.BarWidget {
            width: 60
            height: 26
            bar: fakeBar
            settings: ({
                    dockerEnabled: false
                })
        }
    }

    function port(n, name) {
        return {
            id: "tcp:127.0.0.1:" + n,
            address: "127.0.0.1",
            port: n,
            exposure: "localhost",
            process: name,
            pid: 100 + n,
            owner: "dev",
            cwd: null,
            startedAt: null,
            containerIds: [],
            database: null,
            protocol: null,
            state: "running"
        };
    }
    function portsReply(rows) {
        return JSON.stringify({
            schemaVersion: 1,
            kind: "ports",
            ok: true,
            errors: [],
            data: {
                ports: rows,
                sqlite: []
            }
        });
    }
    function createWidget() {
        const widget = createTemporaryObject(widgetComponent, suite);
        verify(widget !== null);
        const worker = findChild(widget, "collector");
        verify(worker !== null);
        tryCompare(worker, "launches", 1);
        compare(widget.job.scope, "ports");
        return {
            widget: widget,
            worker: worker
        };
    }
    function settle(widget) {
        tryVerify(function () {
            return widget.job === null;
        }, 1000);
    }

    function test_resultIsUsedWhenTheStreamEndsAfterExit() {
        const t = createWidget();
        t.worker.exit(0);
        verify(t.widget.busy, "must wait for stdout");
        t.worker.finishStream(portsReply([port(3000, "vite")]));
        settle(t.widget);
        compare(t.widget.serviceCount, 1);
        compare(t.widget.errorText, "");
        verify(t.widget.lastUpdate > 0);
    }

    function test_failureWithoutDiagnosticsNamesTheExitCode() {
        const t = createWidget();
        t.worker.finishStream("");
        t.worker.exit(127);
        settle(t.widget);
        verify(t.widget.hasError);
        verify(t.widget.errorText.indexOf("exit 127") >= 0, t.widget.errorText);
    }

    function test_collectorThatNeverStartsIsReportedPromptly() {
        const t = createWidget();
        // Quickshell drops `running` without an exit signal when the program cannot be started.
        t.worker.running = false;
        settle(t.widget);
        verify(t.widget.errorText.indexOf("could not start") >= 0, t.widget.errorText);
    }

    function test_settingsChangeDiscardsTheRunningResult() {
        const t = createWidget();
        t.widget.settings = {
            dockerEnabled: false,
            sortBy: "name"
        };
        t.worker.finishStream(portsReply([port(3000, "vite")]));
        t.worker.exit(0);
        tryCompare(t.worker, "launches", 2);
        compare(t.widget.serviceCount, 0);
    }

    function test_logRequestWaitsForTheBusyWorkerAndIsDroppedOnClose() {
        const t = createWidget();
        t.widget.settings = {
            dockerEnabled: true
        };
        t.widget.open();
        tryVerify(function () {
            return t.widget.opened;
        });
        t.widget.requestLogs(cid);
        compare(t.worker.launches, 1, "a running job must not be replaced");
        verify(t.widget.logs.loading);
        t.worker.finishStream("");
        t.worker.exit(1);
        tryCompare(t.worker, "launches", 2);
        verify(t.worker.command.indexOf("logs") >= 0, JSON.stringify(t.worker.command));
        t.widget.close();
        t.worker.finishStream(JSON.stringify({
            schemaVersion: 1,
            kind: "logs",
            ok: true,
            errors: [],
            data: {
                containerId: cid,
                text: "late",
                truncated: false
            }
        }));
        t.worker.exit(0);
        tryVerify(function () {
            return t.widget.job === null || t.widget.job.scope !== "logs";
        });
        compare(t.widget.logs.text, "");
    }

    function test_dockerTroubleDoesNotMakeTheBarUrgent() {
        const t = createWidget();
        t.widget.errors = {
            docker: "docker unavailable",
            assets: "docker unavailable"
        };
        verify(!t.widget.hasError);
        t.widget.errors = {
            ports: "ss unavailable"
        };
        verify(t.widget.hasError);
    }

    // ---- panel keyboard focus ------------------------------------------------------------------

    function openPanel() {
        const t = createWidget();
        t.worker.finishStream(portsReply([port(3000, "vite"), port(5173, "node")]));
        t.worker.exit(0);
        settle(t.widget);
        t.widget.open();
        const panel = t.widget.panel;
        tryVerify(function () {
            return findChild(panel, "keys") !== null;
        });
        const keys = findChild(panel, "keys");
        tryVerify(function () {
            return keys.activeFocus;
        });
        return {
            widget: t.widget,
            panel: panel,
            keys: keys
        };
    }

    function test_lettersInDetailsAreShortcutsAfterSearching() {
        const p = openPanel();
        const search = findChild(p.panel, "search");
        search.forceActiveFocus();
        keyClick(Qt.Key_V);
        compare(p.panel.query, "v");
        p.panel.openDetail(0);
        compare(p.panel.view, "detail");
        keyClick(Qt.Key_C);
        compare(p.panel.query, "v", "c must not be typed into the hidden search field");
        compare(p.panel.view, "detail");
        keyClick(Qt.Key_Escape);
        compare(p.panel.view, "list");
    }

    function test_leavingSettingsReturnsKeysToTheList() {
        const p = openPanel();
        p.panel.toggleSettings();
        const hidden = findChild(p.panel, "hiddenPorts");
        hidden.forceActiveFocus();
        p.panel.toggleSettings();
        compare(p.panel.view, "list");
        keyClick(Qt.Key_J);
        compare(hidden.text, "", "j must not be typed into the hidden settings field");
        compare(p.panel.cursor, 1);
    }

    function test_enterOpensDetailsAfterSavingSettings() {
        const p = openPanel();
        p.panel.toggleSettings();
        findChild(p.panel, "save").click();
        compare(p.panel.view, "list");
        keyClick(Qt.Key_Return);
        compare(p.panel.view, "detail");
    }
}
