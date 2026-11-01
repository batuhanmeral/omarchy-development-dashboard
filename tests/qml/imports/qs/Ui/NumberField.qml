import QtQuick
import QtQuick.Controls.Basic

// Test stand-in for Omarchy's qs.Ui.NumberField: a labelled, editable SpinBox exposed as `field`.
Column {
    id: root
    property string label: ""
    property int value: 0
    property int from: 0
    property int to: 100
    property color foreground: "white"
    property alias field: spin
    SpinBox {
        id: spin
        from: root.from
        to: root.to
        value: root.value
        editable: true
    }
}
