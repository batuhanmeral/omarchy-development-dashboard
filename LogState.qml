import QtQml

// Log text for one container at a time. Every request gets a token; a reply is shown only while
// its token is still the newest, so closing the view or picking another container drops it.
QtObject {
    property string text: ""
    property string containerId: ""
    property bool loading: false
    property bool failed: false
    property int generation: 0

    function begin(id) {
        generation++;
        containerId = id;
        text = "";
        loading = true;
        failed = false;
        return generation;
    }

    function clear() {
        generation++;
        text = "";
        containerId = "";
        loading = false;
        failed = false;
    }

    function accept(token, result) {
        if (token !== generation || !containerId)
            return false;
        loading = false;
        failed = !result.ok;
        text = result.ok ? result.data.text + (result.data.truncated ? "\n[truncated]" : "") : result.errors.join("\n");
        return true;
    }

    function fail(token, message) {
        if (token !== generation || !containerId)
            return false;
        loading = false;
        failed = true;
        text = message;
        return true;
    }
}
