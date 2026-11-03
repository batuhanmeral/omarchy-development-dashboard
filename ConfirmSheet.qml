import QtQuick
import qs.Ui as Ui

Item {
    id: root
    property bool opened: false
    property string message: ""
    property color foreground: "white"
    signal canceled
    signal confirmed
    visible: opened
    z: 100
    onOpenedChanged: if (opened) {
        dialog.selectedIndex = 0;
        forceActiveFocus();
    }
    Keys.onPressed: function (event) {
        if (!opened)
            return;
        if (event.text === "y" && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
            confirmed();
        else
            dialog.handleKey(event);
        event.accepted = true;
    }
    Ui.ConfirmDialog {
        id: dialog
        objectName: "confirmDialog"
        anchors.fill: parent
        opened: root.opened
        selectedIndex: 0
        message: root.message
        cancelText: "Cancel"
        confirmText: "Confirm"
        foreground: root.foreground
        onCanceled: root.canceled()
        onConfirmed: root.confirmed()
    }
}
