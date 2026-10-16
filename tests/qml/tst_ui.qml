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
        compare(entries.get(0).rowState, "running");
        Model.sync(entries, []);
        compare(entries.count, 0);
    }
    function test_settingsRoundTrip() {
        const form = createTemporaryObject(settingsComponent, suite);
        verify(form !== null);
        verify(form.popupColors !== undefined, "Host theme colors must resolve");
        saved.target = form;
        form.load();
        form.submit();
        compare(saved.count, 1);
        const value = saved.signalArguments[0][0];
        compare(value.refreshInterval, 9);
        compare(value.dockerEnabled, false);
        compare(value.hiddenPorts, "53,80");
        compare(value.visibleTabs, "Localhost,Docker");
        compare(value.sqliteFiles, "/work/app.db");
        compare(value.compact, false);
        saved.clear();
    }
}
