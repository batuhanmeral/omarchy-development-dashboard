import QtQml

QtObject {
    property string text: ""
    property string containerId: ""
    property int generation: 0

    function begin(id) {
        generation++;
        containerId = id;
        text = "Loading last 100 log lines…";
        return generation;
    }

    function clear() {
        generation++;
        text = "";
        containerId = "";
    }

    function accept(token, result) {
        if (token !== generation || !containerId)
            return false;
        text = result.ok ? result.data.text + (result.data.truncated ? "\n[truncated]" : "") : result.errors.join("\n");
        return true;
    }
}
