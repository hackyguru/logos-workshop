import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    width: 480
    height: 320

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        width: 360

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: greetingText
            font.pixelSize: 22
            color: "#222"
        }

        TextField {
            id: nameField
            Layout.fillWidth: true
            placeholderText: "Your name"
            onAccepted: greetButton.clicked()
        }

        Button {
            id: greetButton
            Layout.alignment: Qt.AlignHCenter
            text: "Say hi"
            onClicked: {
                const name = nameField.text.trim()
                greetingText = name.length === 0
                    ? "Hello, world!"
                    : "Hello, " + name + "! Welcome to Logos."
            }
        }
    }

    property string greetingText: "Hello, world!"
}
