import QtQuick
import QtTest
import "../.." as Plugin
import "../../Model.js" as Model

TestCase {
    id: suite
    name: "DevelopmentPortsUI"
    width: 480
    height: 600
    when: windowShown

    Component {
        id: settingsComponent
        Plugin.Settings {
            width: 440
            values: ({
                    settingsVersion: 2,
                    refreshInterval: 9,
                    dockerEnabled: false,
                    hiddenPorts: "53,80",
                    visibleTabs: "Localhost,Docker",
                    compact: false,
                    sqliteFiles: "/work/app.db"
                })
        }
    }
    SignalSpy {
        id: saved
        signalName: "saveRequested"
    }
    ListModel {
        id: entries
    }
    function cleanup() {
        saved.clear();
    }
    function createLogs() {
        const component = Qt.createComponent(Qt.resolvedUrl("../../LogState.qml"));
        compare(component.status, Component.Ready, component.errorString());
        return createTemporaryObject(component, suite);
    }
    function test_logReplyAfterCloseIsDiscarded() {
        const logs = createLogs();
        const token = logs.begin("a".repeat(64));
        logs.clear();
        verify(!logs.accept(token, {
            ok: true,
            data: {
                text: "late log content",
                truncated: false
            },
            errors: []
        }));
        compare(logs.text, "");
        compare(logs.containerId, "");
    }
    function test_oldLogReplyCannotReplaceNewRequest() {
        const logs = createLogs();
        const oldToken = logs.begin("a".repeat(64));
        logs.clear();
        const token = logs.begin("b".repeat(64));
        verify(!logs.accept(oldToken, {
            ok: true,
            data: {
                text: "old log content",
                truncated: false
            },
            errors: []
        }));
        verify(logs.accept(token, {
            ok: true,
            data: {
                text: "current log content",
                truncated: true
            },
            errors: []
        }));
        compare(logs.text, "current log content\n[truncated]");
        compare(logs.containerId, "b".repeat(64));
    }
    function test_logErrorsReplaceLoadingText() {
        const logs = createLogs();
        const token = logs.begin("a".repeat(64));
        verify(logs.accept(token, {
            ok: false,
            data: {},
            errors: ["Docker unavailable"]
        }));
        compare(logs.text, "Docker unavailable");
    }
    function test_realListModelSync() {
        const row = {
            id: "tcp:127.0.0.1:3000",
            address: "127.0.0.1",
            port: 3000,
            exposure: "localhost",
            containerIds: [],
            process: "vite",
            protocol: "http",
            state: "running"
        };
        const output = Model.rows({
            ports: [row]
        }, "Localhost", "", "all", Model.config({}));
        Model.sync(entries, output);
        compare(entries.count, 1);
        compare(entries.get(0).title, "vite");
        compare(entries.get(0).lead, "3000");
        compare(entries.get(0).tone, "info");
        compare(entries.get(0).rowState, "running");
        Model.sync(entries, []);
        compare(entries.count, 0);
    }
    function test_logFailuresReplaceLoadingAndStaleFailuresAreDropped() {
        const logs = createLogs();
        const stale = logs.begin("a".repeat(64));
        verify(logs.loading);
        const token = logs.begin("b".repeat(64));
        verify(!logs.fail(stale, "Collector timed out"));
        verify(logs.loading);
        verify(logs.fail(token, "Collector timed out"));
        verify(!logs.loading);
        verify(logs.failed);
        compare(logs.text, "Collector timed out");
        logs.clear();
        verify(!logs.failed);
        compare(logs.text, "");
    }
    function test_settingsRoundTrip() {
        const form = createTemporaryObject(settingsComponent, suite);
        verify(form !== null);
        saved.target = form;
        form.load();
        compare(form.dockerEnabled, false);
        compare(form.compact, false);
        compare(form.tabs.join(","), "Localhost,Docker");
        form.submit();
        compare(saved.count, 1);
        const value = saved.signalArguments[0][0];
        compare(value.refreshInterval, 9);
        compare(value.dockerEnabled, false);
        compare(value.hiddenPorts, "53,80");
        compare(value.visibleTabs, "Localhost,Docker");
        compare(value.sqliteFiles, "/work/app.db");
        compare(value.compact, false);
        compare(value.exposure, "all");
        compare(value.sortBy, "port");
        saved.clear();
    }
    function test_settingsEditsAreSubmittedInTabOrder() {
        const form = createTemporaryObject(settingsComponent, suite);
        saved.target = form;
        form.toggleTab("Databases");
        form.toggleTab("Localhost");
        form.dockerEnabled = true;
        form.sortBy = "name";
        form.exposure = "lan";
        form.submit();
        compare(saved.count, 1);
        const value = saved.signalArguments[0][0];
        compare(value.visibleTabs, "Docker,Databases");
        compare(value.dockerEnabled, true);
        compare(value.sortBy, "name");
        compare(value.exposure, "lan");
        saved.clear();
    }
    function test_settingsRejectInvalidDraftsWithoutSaving() {
        const form = createTemporaryObject(settingsComponent, suite);
        saved.target = form;
        form.toggleTab("Localhost");
        form.toggleTab("Docker");
        form.submit();
        compare(saved.count, 0);
        verify(form.validationError.indexOf("tab") >= 0);
        form.load();
        compare(form.validationError, "");
        compare(form.tabs.join(","), "Localhost,Docker");
        saved.clear();
    }
    function test_typedIntervalIsSavedWithoutLeavingTheField() {
        const form = createTemporaryObject(settingsComponent, suite);
        saved.target = form;
        const field = findChild(form, "refreshInterval").field;
        field.contentItem.text = "30";
        form.submit();
        compare(saved.count, 1);
        compare(saved.signalArguments[0][0].refreshInterval, 30);
        saved.clear();
        field.contentItem.text = "999";
        form.submit();
        compare(saved.count, 0);
        verify(form.validationError.indexOf("2 to 120") >= 0);
        saved.clear();
    }

    function test_dashboardSettingsAndLegacyDraft() {
        const form = createTemporaryObject(settingsComponent, suite);
        saved.target = form;
        form.legacy = {
            found: true,
            installed: true,
            settings: {
                refreshInterval: 17,
                compact: false,
                hiddenPorts: "8080"
            }
        };
        form.importLegacy();
        compare(saved.count, 0);
        compare(form.intervalField.value, 17);
        verify(form.imported);
        findChild(form, "projectRoots").text = "/work";
        findChild(form, "customTools").text = "Aider | aider | --no-auto-commits";
        form.managementEnabled = true;
        form.terminal = "kitty";
        form.submit();
        compare(saved.count, 1);
        const value = saved.signalArguments[0][0];
        compare(value.settingsVersion, 2);
        compare(value.projectRoots, "/work");
        compare(value.customTools, "Aider | aider | --no-auto-commits");
        compare(value.managementEnabled, true);
        compare(value.terminal, "kitty");
        saved.clear();
    }
    function test_visibleTabsMigrationInSettings() {
        const form = createTemporaryObject(settingsComponent, suite);
        form.values = {
            visibleTabs: "Docker"
        };
        form.load();
        compare(form.tabs.join(","), "Overview,Docker,Projects,Tools");
    }

    function test_legacyImportPreservesDashboardOnlySettings() {
        const form = createTemporaryObject(settingsComponent, suite);
        form.values = {
            projectRoots: "/work",
            terminal: "kitty",
            managementEnabled: true,
            favoriteProjects: "/work/app",
            customTools: "Aider | aider"
        };
        form.legacy = {
            found: true,
            settings: {
                refreshInterval: 13
            }
        };
        form.importLegacy();
        saved.target = form;
        form.submit();
        compare(saved.count, 1);
        const value = saved.signalArguments[0][0];
        compare(value.projectRoots, "/work");
        compare(value.terminal, "kitty");
        compare(value.favoriteProjects, "/work/app");
        compare(value.managementEnabled, true);
        saved.clear();
    }
}
