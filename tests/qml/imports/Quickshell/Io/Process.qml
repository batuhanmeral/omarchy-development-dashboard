import QtQuick

// Test stand-in for Quickshell.Io.Process. Nothing is executed: tests read `command`/`launches`
// and drive the stream and exit signals by hand.
QtObject {
    id: root
    property var command: []
    property bool running: false
    property QtObject stdout: null
    property QtObject stderr: null
    property int launches: 0
    property var signals: []
    signal started
    signal exited(int exitCode, int exitStatus)
    onRunningChanged: if (running)
        launches++
    function signal(number) {
        signals = signals.concat([number]);
    }
    // Test helpers.
    function finishStream(text) {
        stdout.text = text;
        stdout.streamFinished();
    }
    function exit(code) {
        running = false;
        exited(code, 0);
    }
}
