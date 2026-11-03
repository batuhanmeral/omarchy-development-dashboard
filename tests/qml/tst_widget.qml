import QtQuick
import QtTest
import "../.." as Plugin
import "../../Model.js" as Model

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

    function cleanup() {
        suite.visible = false;
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
    function reply(scope, data, ok, errors) {
        return JSON.stringify({
            schemaVersion: 1,
            kind: scope,
            ok: ok === undefined ? true : ok,
            errors: errors || [],
            data: data
        });
    }
    function projectRow() {
        return {
            id: "project:/work/app",
            path: "/work/app",
            root: "/work",
            name: "app",
            gitState: "clean",
            branch: "main"
        };
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
            sqliteFiles: "/work/app.db"
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
        panel.selectTab("Localhost");
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

    function dockerPanel(management) {
        const p = openPanel();
        p.widget.settings = {
            settingsVersion: 2,
            dockerEnabled: true,
            managementEnabled: management
        };
        p.widget.inventory = {
            containers: [
                {
                    id: cid,
                    name: "<img src=x>",
                    state: "running",
                    publishedPorts: []
                }
            ]
        };
        p.panel.selectTab("Docker");
        p.panel.openDetail(0);
        return p;
    }
    function test_confirmDefaultsToCancelAndEnterCancels() {
        const p = dockerPanel(true);
        keyClick(Qt.Key_X);
        const dialog = findChild(p.panel, "confirmDialog");
        verify(dialog.opened);
        compare(dialog.selectedIndex, 0);
        compare(dialog.message, 'Stop container “<img src=x>”?');
        compare(findChild(dialog, "confirmMessage").textFormat, Text.PlainText);
        keyClick(Qt.Key_Return);
        verify(!dialog.opened);
        compare(findChild(p.widget, "operation").launches, 0);
    }
    function test_yConfirmsActionAndResultNotifiesAndRefreshes() {
        const p = dockerPanel(true);
        const collector = findChild(p.widget, "collector");
        const now = Date.now();
        p.widget.lastPoll = {
            ports: now,
            docker: now,
            assets: now,
            tools: now,
            legacy: now
        };
        if (p.widget.job) {
            collector.finishStream(reply(p.widget.job.scope, {}));
            collector.exit(0);
        }
        settle(p.widget);
        const launches = collector.launches;
        keyClick(Qt.Key_X);
        keyClick(Qt.Key_Y);
        const operation = findChild(p.widget, "operation");
        compare(operation.launches, 1);
        compare(operation.command.slice(2).join("|"), "docker-stop|--container-id=" + cid);
        verify(p.widget.operation.running);
        operation.exit(0);
        verify(p.widget.operation.running, "wait for stream even if exit arrives first");
        operation.finishStream(JSON.stringify({
            schemaVersion: 1,
            kind: "action",
            action: "docker-stop",
            ok: true,
            errors: [],
            data: {
                containerId: cid,
                state: "exited"
            }
        }));
        verify(!p.widget.operation.running);
        verify(!p.widget.messageUrgent);
        verify(p.widget.message.indexOf("Stopped") >= 0, p.widget.message);
        tryCompare(collector, "launches", launches + 1, 250);
        compare(p.widget.job.scope, "ports");
        compare(collector.command[2], "ports");
    }
    function test_managementDisabledAndInvalidActionCannotLaunch() {
        const p = dockerPanel(false);
        keyClick(Qt.Key_X);
        compare(findChild(p.widget, "operation").launches, 0);
        verify(!p.widget.runOperation("stop", p.panel.selectedRow, {}));
        p.widget.settings = {
            managementEnabled: true
        };
        verify(p.widget.runOperation("stop", p.panel.selectedRow, {}));
        const operation = findChild(p.widget, "operation");
        operation.finishStream("not json");
        operation.exit(0);
        verify(p.widget.messageUrgent);
        verify(p.widget.message.indexOf("Invalid") >= 0, p.widget.message);
    }
    function test_fixedTabShortcutsAndHiddenTabs() {
        const p = openPanel();
        const names = ["Localhost", "Docker", "Images", "Databases", "Projects", "Tools"];
        for (let i = 0; i < 6; i++) {
            keyClick(Qt.Key_1 + i);
            compare(p.panel.tab, names[i]);
        }
        // There is no Overview section any more; 0 is not a section key.
        keyClick(Qt.Key_0);
        compare(p.panel.tab, "Tools");
        p.widget.settings = {
            settingsVersion: 2,
            visibleTabs: "Localhost,Tools",
            dockerEnabled: false
        };
        keyClick(Qt.Key_2);
        compare(p.panel.tab, "Tools");
        keyClick(Qt.Key_1);
        compare(p.panel.tab, "Localhost");
    }
    function test_importIsDraftUntilSave() {
        const p = openPanel();
        fakeBar.saved = [];
        p.widget.inventory = {
            legacy: {
                found: true,
                installed: true,
                settings: {
                    refreshInterval: 19,
                    hiddenPorts: "80"
                }
            }
        };
        p.panel.toggleSettings();
        const form = findChild(p.panel, "settings");
        form.importLegacy();
        compare(fakeBar.saved.length, 0);
        compare(form.intervalField.value, 19);
        form.submit();
        compare(fakeBar.saved.length, 1);
        compare(fakeBar.saved[0].settingsVersion, 2);
        compare(fakeBar.saved[0].hiddenPorts, "80");
    }
    function test_newCollectorArgumentsAndSingleOperation() {
        const t = createWidget();
        t.widget.settings = {
            projectRoots: "/work/a\n/work/b",
            projectDepth: 4,
            customTools: "Aider | aider | --no-auto-commits",
            managementEnabled: true
        };
        t.worker.finishStream(portsReply([]));
        t.worker.exit(0);
        tryCompare(t.worker, "launches", 2);
        t.worker.finishStream(portsReply([]));
        t.worker.exit(0);
        settle(t.widget);
        t.widget.start("projects", null);
        compare(t.worker.command.slice(2).join("|"), "projects|--project-root=/work/a|--project-root=/work/b|--project-depth=4");
        t.worker.finishStream(JSON.stringify({
            schemaVersion: 1,
            kind: "projects",
            ok: true,
            errors: [],
            data: {
                projects: [],
                skipped: 0
            }
        }));
        t.worker.exit(0);
        settle(t.widget);
        t.widget.start("tools", null);
        compare(t.worker.command.slice(2).join("|"), "tools|--custom-tool=Aider | aider | --no-auto-commits");
        verify(t.widget.runOperation("stop", Model.viewRow({
            id: cid,
            name: "web",
            state: "running",
            publishedPorts: []
        }, "container"), {}));
        verify(!t.widget.runOperation("stop", Model.viewRow({
            id: cid
        }, "container"), {}));
    }

    function test_searchIsResetWhenSwitchingTabs() {
        const p = openPanel();
        const search = findChild(p.panel, "search");
        search.forceActiveFocus();
        keyClick(Qt.Key_V);
        compare(search.text, "v");
        p.panel.selectTab("Docker");
        compare(search.text, "");
    }
    function test_projectShortcutsAndToolLaunch() {
        const p = openPanel();
        p.widget.settings = {
            projectRoots: "/work",
            dockerEnabled: false
        };
        p.widget.inventory = {
            projects: [
                {
                    id: "project:/work/app",
                    path: "/work/app",
                    root: "/work",
                    name: "app",
                    branch: "main",
                    gitState: "clean"
                }
            ],
            tools: [
                {
                    id: "claude",
                    name: "Claude",
                    available: true,
                    path: "/bin/claude"
                }
            ]
        };
        p.panel.selectTab("Projects");
        keyClick(Qt.Key_T);
        const operation = findChild(p.widget, "operation");
        compare(operation.command[2], "open-terminal");
        verify(operation.command.indexOf("--path=/work/app") >= 0);
        operation.finishStream(JSON.stringify({
            schemaVersion: 1,
            kind: "action",
            action: "open-terminal",
            ok: true,
            errors: [],
            data: {
                launched: "terminal"
            }
        }));
        operation.exit(0);
        // Favorites were removed: F neither saves settings nor changes the project.
        fakeBar.saved = [];
        keyClick(Qt.Key_F, Qt.ShiftModifier);
        compare(fakeBar.saved.length, 0);
        keyClick(Qt.Key_A);
        compare(p.panel.tab, "Tools");
        compare(p.panel.toolProject, "/work/app");
        keyClick(Qt.Key_Return);
        compare(operation.command[2], "launch-tool");
        verify(operation.command.indexOf("--path=/work/app") >= 0);
        verify(operation.command.indexOf("--tool=claude") >= 0);
    }
    function test_textInputsBlockNewShortcuts() {
        const p = dockerPanel(true);
        p.panel.back();
        const search = findChild(p.panel, "search");
        search.forceActiveFocus();
        keyClick(Qt.Key_X);
        keyClick(Qt.Key_U);
        keyClick(Qt.Key_R, Qt.ShiftModifier);
        keyClick(Qt.Key_5);
        compare(search.text, "xur5");
        compare(p.panel.tab, "Docker");
        compare(findChild(p.widget, "operation").launches, 0);
        verify(!p.panel.confirming);
    }
    function test_confirmMouseButtonsAndUnavailableTools() {
        const p = dockerPanel(true);
        keyClick(Qt.Key_X);
        findChild(p.panel, "cancelConfirm").click();
        verify(!p.panel.confirming);
        compare(findChild(p.widget, "operation").launches, 0);
        keyClick(Qt.Key_R, Qt.ShiftModifier);
        verify(p.panel.confirming);
        findChild(p.panel, "acceptConfirm").click();
        compare(findChild(p.widget, "operation").command[2], "docker-restart");
        p.panel.toolProject = "";
        p.panel.launchTool(Model.viewRow({
            id: "claude",
            name: "Claude",
            available: false,
            reason: "not found"
        }, "tool"));
        verify(p.widget.message.indexOf("Choose a project") >= 0, p.widget.message);
    }

    function test_operationTimeoutKeepsSingleFlightUntilExit() {
        const p = dockerPanel(true);
        p.widget.runOperation("stop", p.panel.selectedRow, {});
        const operation = findChild(p.widget, "operation");
        const watchdog = findChild(p.widget, "operationWatchdog");
        const forceStop = findChild(p.widget, "operationForceStop");
        verify(watchdog !== null);
        verify(forceStop !== null);
        watchdog.interval = 1;
        watchdog.restart();
        tryCompare(operation, "signals", [15]);
        forceStop.interval = 1;
        forceStop.restart();
        tryCompare(operation, "signals", [15, 9]);
        verify(p.widget.operation.running);
        verify(!p.widget.runOperation("stop", p.panel.selectedRow, {}));
        operation.exit(1);
        operation.finishStream("");
        verify(!p.widget.operation.running);
        verify(p.widget.messageUrgent);
        verify(p.widget.message.indexOf("timed out") >= 0);
    }

    function test_migratedTabsIncludeNewSectionsWithoutOverview() {
        const p = openPanel();
        p.widget.settings = {
            visibleTabs: "Localhost,Docker",
            projectRoots: "/work",
            dockerEnabled: false
        };
        p.widget.inventory = {
            projects: [
                {
                    id: "project:/work/app",
                    path: "/work/app",
                    root: "/work",
                    name: "app",
                    gitState: "clean"
                }
            ]
        };
        compare(p.widget.cfg.tabs.join(","), "Localhost,Docker,Projects,Tools");
        verify(p.widget.saveSettings({
            compact: false
        }));
        compare(p.widget.cfg.tabs.join(","), "Localhost,Docker,Projects,Tools");
    }

    function test_scopeWarningsAreIsolatedAndPartialProjectsRemainVisible() {
        const p = openPanel();
        // The production popup uses its own window; expose the Item-based test popup.
        suite.visible = true;
        p.panel.parent.visible = true;
        p.widget.settings = {
            projectRoots: "/work",
            dockerEnabled: true
        };
        p.widget.inventory = {
            projects: [projectRow()],
            tools: [
                {
                    id: "claude",
                    name: "Claude",
                    available: true,
                    path: "/bin/claude"
                }
            ]
        };
        p.widget.errors = {
            projects: "Project scan stopped early: budget exceeded",
            tools: "tool scan failed",
            docker: "docker failed"
        };
        p.panel.selectTab("Projects");
        const warning = findChild(p.panel, "scopeWarning");
        verify(warning !== null);
        verify(warning.visible);
        compare(warning.text, "Project scan stopped early: budget exceeded");
        compare(p.panel.entries.count, 1);
        p.panel.selectTab("Tools");
        compare(warning.text, "tool scan failed");
        verify(warning.visible);
        p.panel.selectTab("Docker");
        compare(warning.text, "docker failed");
        const empty = findChild(p.panel, "emptyState");
        compare(empty.text, "docker failed");
        p.widget.errors = {
            tools: "tool scan failed"
        };
        compare(empty.text, "No containers.");
        p.panel.selectTab("Projects");
        p.widget.inventory = {};
        p.widget.errors = {
            projects: "Collector timed out; showing previous data."
        };
        compare(empty.text, "Collector timed out; showing previous data.");
        p.panel.selectTab("Tools");
        p.widget.errors = {
            tools: "Tool collection failed."
        };
        compare(empty.text, "Tool collection failed.");
    }
    function test_partialProjectsReplyKeepsRowsAndShowsDiagnostic() {
        const p = openPanel();
        suite.visible = true;
        p.panel.parent.visible = true;
        p.widget.settings = {
            projectRoots: "/work",
            dockerEnabled: false
        };
        const worker = findChild(p.widget, "collector");
        if (p.widget.job) {
            worker.finishStream(reply(p.widget.job.scope, {}));
            worker.exit(0);
        }
        // Hold unrelated scopes fresh so this test controls the projects run.
        p.widget.lastPoll = {
            ports: Date.now(),
            tools: Date.now(),
            legacy: Date.now(),
            projects: Date.now()
        };
        settle(p.widget);
        p.widget.start("projects", null);
        worker.finishStream(reply("projects", {
            projects: [projectRow()],
            skipped: 2
        }, false, ["Project scan stopped early: budget exceeded"]));
        worker.exit(1);
        p.panel.selectTab("Projects");
        compare(p.panel.entries.count, 1);
        const warning = findChild(p.panel, "scopeWarning");
        verify(warning !== null);
        verify(warning.visible);
        compare(warning.text, "Project scan stopped early: budget exceeded");
    }
    function test_removingLastProjectRootClearsProjectsAndPicker() {
        const p = openPanel();
        p.widget.settings = {
            projectRoots: "/work",
            dockerEnabled: false
        };
        p.widget.inventory = {
            projects: [projectRow()],
            skipped: 3
        };
        compare(p.panel.projectOptions.length, 1);
        p.widget.settings = {
            projectRoots: "",
            dockerEnabled: false
        };
        compare(p.widget.inventory.projects.length, 0);
        compare(p.widget.inventory.skipped, 0);
        compare(p.panel.projectOptions.length, 0);
        compare(p.panel.toolProject, "");
    }
    function test_disappearingRowCancelsConfirmationAndRestoresKeys() {
        const p = dockerPanel(true);
        keyClick(Qt.Key_X);
        verify(p.panel.confirming);
        p.widget.inventory = {
            containers: []
        };
        verify(!p.panel.confirming);
        verify(p.keys.activeFocus);
        keyClick(Qt.Key_5);
        compare(p.panel.tab, "Projects");
        compare(findChild(p.widget, "operation").launches, 0);
    }
    function test_viewChangeDoesNotStealConfirmationFocus() {
        const p = dockerPanel(true);
        keyClick(Qt.Key_X);
        verify(p.panel.confirming);
        p.panel.view = "logs";
        verify(!p.keys.activeFocus);
        keyClick(Qt.Key_Escape);
        verify(!p.panel.confirming);
        verify(p.keys.activeFocus);
    }
    function test_staleLegacyResultIsRetriedAfterCollectionSettingsChange() {
        const t = createWidget();
        t.worker.finishStream(portsReply([]));
        t.worker.exit(0);
        settle(t.widget);
        t.widget.start("legacy", null);
        t.widget.settings = {
            dockerEnabled: false,
            sqliteFiles: "/work/app.db"
        };
        t.worker.finishStream(reply("legacy", {
            legacy: {
                found: true,
                installed: false,
                settings: {
                    refreshInterval: 17
                }
            }
        }));
        t.worker.exit(0);
        verify(!t.widget.legacyAttempted);
        verify(t.widget.inventory.legacy === undefined);
        // Settling the refreshed ports leaves all open-panel scopes fresh except legacy.
        tryCompare(t.worker, "launches", 3);
        t.worker.finishStream(portsReply([]));
        t.worker.exit(0);
        settle(t.widget);
        t.widget.lastPoll = {
            ports: Date.now(),
            tools: Date.now()
        };
        t.widget.open();
        tryVerify(function () {
            return t.widget.job && t.widget.job.scope === "legacy";
        });
        t.worker.finishStream(reply("legacy", {
            legacy: {
                found: false,
                installed: false
            }
        }));
        t.worker.exit(0);
        verify(t.widget.legacyAttempted);
    }
    function test_displaySettingsKeepRunningCollectorAndPollTimes() {
        const t = createWidget();
        const originalGeneration = t.widget.generation;
        const originalPoll = JSON.stringify(t.widget.lastPoll);
        const changes = {
            favoriteProjects: "/work/app",
            sortBy: "name",
            compact: false,
            terminal: "kitty",
            editor: "code",
            managementEnabled: true,
            visibleTabs: "Tools",
            exposure: "lan",
            hiddenPorts: "80",
            refreshInterval: 12
        };
        Object.keys(changes).forEach(function (key) {
            const next = Object.assign({}, t.widget.settings);
            next[key] = changes[key];
            t.widget.settings = next;
            compare(t.widget.generation, originalGeneration, key);
            compare(JSON.stringify(t.widget.lastPoll), originalPoll, key);
        });
        t.worker.finishStream(portsReply([port(3000, "vite")]));
        t.worker.exit(0);
        settle(t.widget);
        compare(t.widget.inventory.ports.length, 1);
        compare(t.worker.launches, 1);
    }
    function test_collectorSettingsInvalidateRunningGeneration() {
        const changes = {
            dockerEnabled: true,
            sqliteFiles: "/work/app.db",
            projectRoots: "/work",
            projectDepth: 4,
            customTools: "Aider | aider"
        };
        Object.keys(changes).forEach(function (key) {
            const t = createWidget();
            const old = t.widget.generation;
            const next = Object.assign({}, t.widget.settings);
            next[key] = changes[key];
            t.widget.settings = next;
            compare(t.widget.generation, old + 1, key);
        });
    }
    function test_optionShapedCustomToolUsesAttachedValue() {
        const t = createWidget();
        t.widget.settings = {
            dockerEnabled: false,
            customTools: "-x|aider"
        };
        t.worker.finishStream(portsReply([]));
        t.worker.exit(0);
        tryCompare(t.worker, "launches", 2);
        t.worker.finishStream(portsReply([]));
        t.worker.exit(0);
        settle(t.widget);
        t.widget.start("tools", null);
        compare(t.worker.command.slice(2).join("|"), "tools|--custom-tool=-x|aider");
    }
    function test_initialTabIsFirstVisibleTab() {
        const t = createWidget();
        t.widget.open();
        compare(t.widget.panel.tab, "Localhost");
        t.widget.close();
        const hidden = createWidget();
        hidden.widget.settings = {
            settingsVersion: 2,
            visibleTabs: "Tools,Docker",
            dockerEnabled: false
        };
        hidden.widget.open();
        compare(hidden.widget.panel.tab, "Docker");
    }
}
