import QtQuick

// Test stand-in for Quickshell.Io.FileView: never touches the disk.
QtObject {
    property string path: ""
    property bool printErrors: true
    signal loaded
    signal loadFailed(int error)
    function text() {
        return "";
    }
    function reload() {
    }
}
