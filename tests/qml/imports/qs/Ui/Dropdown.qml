import QtQuick

Item {
    property string label: ""
    property string value: ""
    property var options: []
    property color foreground: "white"
    property bool popupOpen: false
    signal changed(string value)
    function open() {
        popupOpen = true;
    }
    function close() {
        popupOpen = false;
    }
    implicitHeight: 48
}
