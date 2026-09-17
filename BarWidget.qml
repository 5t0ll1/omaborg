import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "oma.borg"

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  // No `property var settings` here: BarWidget already declares it and the bar
  // host injects the shell.json entry into that declaration. Redeclaring
  // shadows it, and every setting silently falls back to its default.

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.settings = root.settings
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Service {
    id: borg
    settings: root.settings
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { borg.refresh(); return "ok" }
    function backup(): string { borg.startBackup(); return "ok" }
    function status(): string { return borg.stateText }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: borg.needsAction ? (borg.plan.title + " — click for what to do") : borg.stateText
    iconComponent: Component {
      Item {
        anchors.fill: parent
        Text {
          text: "󰆼"
          color: {
            if (borg.needsAction) return root.bar ? root.bar.urgent : Color.urgent
            if (borg.state === "stale" || borg.state === "away") return Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.55)
            return root.bar ? root.bar.foreground : Color.foreground
          }
          opacity: borg.backupRunning ? pulse.opacity : 1.0
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.bar.iconFont
          anchors.centerIn: parent
        }
        Rectangle {
          visible: borg.needsAction
          width: Math.max(7, parent.width * 0.42)
          height: width
          radius: width / 2
          color: root.bar ? root.bar.urgent : Color.urgent
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          border.width: 1
          border.color: root.bar ? (root.bar.barBackground || Color.background) : Color.background
          Text {
            anchors.centerIn: parent
            text: "!"
            color: Color.background
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Math.max(6, parent.height * 0.72)
            font.bold: true
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (panelLoader.item) {
          panelLoader.item.showArchives = true
          panelLoader.item.showActions = false
        }
        root.open()
      } else if (buttonCode !== Qt.MiddleButton) {
        if (panelLoader.item) {
          panelLoader.item.showArchives = false
          panelLoader.item.showActions = true
        }
        root.open()
      }
    }
  }

  SequentialAnimation {
    id: pulse
    property real opacity: 1
    running: borg.backupRunning
    loops: Animation.Infinite
    NumberAnimation { target: pulse; property: "opacity"; from: 1.0; to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
    NumberAnimation { target: pulse; property: "opacity"; from: 0.45; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
    onStopped: pulse.opacity = 1
  }
}
