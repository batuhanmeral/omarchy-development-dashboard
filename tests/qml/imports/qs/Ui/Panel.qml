import QtQuick

// Test stand-in for Omarchy's qs.Ui.Panel open/close lifecycle.
Item {
    id: root
    property var bar: null
    property string moduleName: ""
    property var settings: ({})
    property string ipcTarget: ""
    property bool popoutSwitchClosing: false
    property bool opened: false
    function open() {
        opened = true;
    }
    function close() {
        opened = false;
    }
    function toggle() {
        opened = !opened;
    }
    function closeForPopoutSwitch() {
        close();
    }
}
