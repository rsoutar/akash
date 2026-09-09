import QtQuick
import Quickshell.Io

// One place for the bookkeeping every child process needs.
//
// A process that cannot be started emits neither `started` nor `exited`, and
// goes from running to not running in silence. `exited` fires before
// `running` drops, so a drop with nothing recorded is a fork that never
// happened — which has to be answered, or the caller waits on a reply that
// will never come. The `answered` flag closes that gap here, once, instead of
// at every call site — and `launch()` resets it on every run, so the flag
// from a previous run can never mask the next one.
//
// A collector that decides anything is wrong too: `onStreamFinished` fires
// before the exit code exists, so a transfer cut short by the time or size
// ceiling would read there as one that completed. This component collects and
// reports; the owner decides in the handlers.
Process {
  id: proc

  // Set when the owner is about to stop the process itself: the exit that
  // follows is a cancellation, not an answer, and counting it would inflate
  // failure backoff or report an outage the user caused by flipping a switch.
  property bool cancelRequested: false

  // Guards the fork-that-never-ran case; `output` is the collected stdout,
  // to be decided on by the owner's handlers.
  property bool answered: false
  readonly property string output: out.text

  // The one way to run a command. Resetting `answered` here rather than at
  // the call sites means a run can never inherit the previous run's answer.
  function launch(commandLine) {
    answered = false
    command = commandLine
    running = true
  }

  // Exactly one of these fires per attempt. `responded` carries a real exit
  // code, or -1 for a fork that never happened.
  signal responded(int exitCode, string output)
  signal cancelled()

  onExited: function(exitCode) {
    answered = true
    if (cancelRequested) {
      cancelRequested = false
      proc.cancelled()
      return
    }
    proc.responded(exitCode, out.text)
  }

  onRunningChanged: {
    if (running || answered) return
    if (cancelRequested) {
      cancelRequested = false
      proc.cancelled()
      return
    }
    proc.responded(-1, "")
  }

  stdout: StdioCollector { id: out; waitForEnd: true }
}
