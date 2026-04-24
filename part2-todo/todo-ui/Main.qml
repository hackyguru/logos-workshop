import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 520
    height: 640

    property var todos: []

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        Text {
            text: "Todo"
            font.pixelSize: 24
            font.weight: Font.DemiBold
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            TextField {
                id: titleField
                Layout.fillWidth: true
                placeholderText: "What needs to be done?"
                onAccepted: addButton.clicked()
            }

            Button {
                id: addButton
                text: "Add"
                onClicked: {
                    const title = titleField.text.trim()
                    if (title.length === 0) return
                    callTodo("addTodo", [title])
                    titleField.text = ""
                    refresh()
                }
            }
        }

        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: root.todos
            spacing: 6
            clip: true

            delegate: Rectangle {
                width: listView.width
                height: 44
                color: modelData.completed ? "#f3f6f9" : "white"
                border.color: "#dfe3e8"
                border.width: 1
                radius: 6

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 10

                    CheckBox {
                        checked: modelData.completed
                        enabled: !modelData.completed
                        onToggled: {
                            if (!modelData.completed) {
                                callTodo("completeTodo", [modelData.id])
                                refresh()
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: modelData.title
                        elide: Text.ElideRight
                        color: modelData.completed ? "#7c8a99" : "#1f2d3d"
                        font.pixelSize: 14
                        font.strikeout: modelData.completed
                        verticalAlignment: Text.AlignVCenter
                    }

                    Button {
                        text: "×"
                        font.pixelSize: 16
                        flat: true
                        onClicked: {
                            callTodo("removeTodo", [modelData.id])
                            refresh()
                        }
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: root.todos.length === 0
                text: "No todos yet — add one above."
                color: "#9aa5b1"
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: statusText()
                color: "#6b7a89"
                font.pixelSize: 12
            }

            Button {
                text: "Refresh"
                onClicked: refresh()
            }

            Button {
                text: "Clear all"
                enabled: root.todos.length > 0
                onClicked: {
                    callTodo("clearAll", [])
                    refresh()
                }
            }
        }
    }

    // ── Logos bridge helpers ─────────────────────────────────────────────

    function callTodo(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("todo", method, args)
    }

    function refresh() {
        const json = callTodo("listTodos", [])
        if (json === null || json === undefined) {
            root.todos = []
            return
        }
        try {
            root.todos = JSON.parse(json)
        } catch (e) {
            console.log("listTodos parse error:", e, "payload:", json)
            root.todos = []
        }
    }

    function statusText() {
        const total = root.todos.length
        if (total === 0) return ""
        let done = 0
        for (let i = 0; i < total; i++) if (root.todos[i].completed) done++
        return done + " of " + total + " done"
    }

    Component.onCompleted: refresh()
}
