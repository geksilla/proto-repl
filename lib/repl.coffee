{Task, Emitter} = require 'atom'
path = require 'path'
fs = require('fs')
ReplProcess = require.resolve './repl-process'
ReplTextEditor = require './repl-text-editor'
ReplHistory = require './repl-history'
nrepl = require('nrepl-client')
ClojureVersion = require './clojure-version'

replHelpText = ";; This Clojure REPL is divided into two areas, top and bottom, delimited by a line of dashes. The top area shows code that's been executed in the REPL, standard out from running code, and the results of executed expressions. The bottom area allows Clojure code to be entered. The code can be executed by pressing shift+enter.\n\n;; Try it now by typing (+ 1 1) in the bottom section and pressing shift+enter.\n\n;; Working in another Clojure file and sending forms to the REPL is the most efficient way to work. Use the following key bindings to send code to the REPL. See the settings for more keybindings.\n\n;; ctrl-, then b - execute block. Finds the block of Clojure code your cursor is in and executes that.\n\n;; Try it now. Put your cursor inside this block and press ctrl and comma together,\n;; release, then press b.\n(+ 2 3)\n\n;; ctrl-, s - Executes the selection. Sends the selected text to the REPL.\n\n;; Try it now. Select these three lines and press ctrl and comma together, \n;; release, then press s.\n(println \"hello 1\")\n(println \"hello 2\")\n(println \"hello 3\")\n\n;; You can disable this help text in the settings.\n"

# The path to a default project to use if proto repl is started outside of a leiningen project
defaultProjectPath = "#{atom.packages.getPackageDirPaths()[0]}/proto-repl/proto-no-proj"

# The code to send to the repl to exit.
EXIT_CMD="(System/exit 0)"

module.exports =

# Represents the REPL where code is executed and displayed. It is split into three
# parts. 1. The running process. 2. The nRepl connection, 3. The text editor where
# results are displayed.
class Repl
  emitter: null

  # The running java process
  process: null

  # The nrepl connection
  conn: null

  # The text editor where results are displayed or commands can be enterered
  replTextEditor: null

  # A map of code execution extension names to callback functions.
  codeExecutionExtensions: null

  constructor: (@codeExecutionExtensions)->
    @emitter = new Emitter
    @replTextEditor = new ReplTextEditor()
    @replHistory = new ReplHistory()

    # Connect together repl text editor and history
    @replTextEditor.onHistoryBack =>
      if @running()
        @replHistory.setCurrentText(@replTextEditor.enteredText())
        @replTextEditor.setEnteredText(@replHistory.back())

    @replTextEditor.onHistoryForward =>
      if @running()
        @replHistory.setCurrentText(@replTextEditor.enteredText())
        @replTextEditor.setEnteredText(@replHistory.forward())

    @replTextEditor.onDidOpen =>
      # Display the help text when the repl opens.
      if atom.config.get("proto-repl.displayHelpText")
        @appendText(replHelpText)

    # The window was closed
    @replTextEditor.onDidClose =>
      try
        # I couldn't refer to sendToRepl directly here. I'm not sure why.
        # Tell the process to shutdown
        @conn?.eval(EXIT_CMD)
        @conn = null
        # Kill the process to make sure.
        @process?.send event: 'kill'
        @process = null
        @replTextEditor = null
        @emitter.emit 'proto-repl-repl:close'
      catch error
        console.log("Warning error while closing: " + error)

  # Calls the callback after the REPL has been started
  onDidStart: (callback)->
    @emitter.on 'proto-repl-repl:start', callback

  # Returns true if the process is running
  running: ->
    @process != null && @conn != null

  # Starts the process unless it's already running.
  startProcessIfNotRunning: (projectPath=null)->
    if @process
      @appendText("REPL already running")
      return

    # Use the projectPath passed in or default to the root directory of the project.
    unless projectPath?
      projectPath = atom.project.getPaths()[0]

    # If we're not in a project or there isn't a leiningen project file use
    # the default project
    if !(projectPath?) || !fs.existsSync(projectPath + "/project.clj")
      projectPath = defaultProjectPath

    @replTextEditor.onDidOpen =>
      @appendText("Starting REPL in #{projectPath}\n")

    # Start the repl process as a background task
    @process = Task.once ReplProcess,
                         path.resolve(projectPath),
                         atom.config.get('proto-repl.leinPath').replace("/lein",""),
                         atom.config.get('proto-repl.leinArgs').split(" ")

    # The process sends stdout
    @process.on 'proto-repl-process:data', (data) =>
      @appendText(data)

    # The nREPL port was captured from output
    @process.on 'proto-repl-process:nrepl-port', (port) =>
      # Setup the nREPL connection
      @conn = nrepl.connect({port: port, verbose: false})
      @conn.once 'connect', =>
        # Create a persistent session
        @conn.clone (err, messages)=>
          @session = messages[0]["new-session"]

          # Determine the Clojure Version
          @conn.eval "*clojure-version*", "user", @session, (err, messages)=>
            value = (msg.value for msg in messages)[0]
            @clojureVersion = new ClojureVersion(protoRepl.parseEdn(value))
            unless @clojureVersion.isSupportedVersion()
              @appendText("WARNING: This version of Clojure is not supported by Proto REPL. You may experience issues.")

          @emitter.emit 'proto-repl-repl:start'

        # Log any output from the nRepl connection messages
        @conn.messageStream.on "messageSequence", (id, messages)=>
          for msg in messages
            if msg.out
              @appendText(msg.out)

    # The process exited.
    @process.on 'proto-repl-process:exit', ()=>
      @appendText("\nREPL Closed\n")
      # The REPL Text editor may or may not be still open at this point. We track
      # that separately.
      @process = null
      @conn = null

  # Invoked when the REPL window is closed.
  onDidClose: (callback)->
    @emitter.on 'proto-repl-repl:close', callback

  # Appends text to the display area of the text editor.
  appendText: (text)->
    @replTextEditor?.appendText(text)

  # Sends the given code to the REPL and calls the given callback with the results
  sendToRepl: (text, resultHandler)->
    return null unless @running()
    @conn.eval text, "user", @session, (err, messages)=>
      for msg in messages
        if msg.value
          resultHandler(value: msg.value)
        else if msg.err
          resultHandler(error: msg.err)

  # Makes an inline displaying result handler
  # * editor - the text editor to show the inline display in
  # * range - the range of code to display the inline result next to
  # * valueToTreeFn - a function that can convert the result value into the tree
  # of content for inline display.
  makeInlineHandler: (editor, range, valueToTreeFn)->
    (result) =>
      if result.value
        tree = valueToTreeFn(result.value)
      else
        tree = [result.error]
      view = @ink.tree.treeView(tree[0], tree.slice(1), {})
      new @ink.Result editor, [range.start.row, range.end.row],
        content: view

  # Wraps the given code in an eval and a read-string. This safely handles
  # unbalanced parentheses, other kinds of invalid code, and handling reader
  # conditionals. http://clojure.org/guides/reader_conditionals
  wrapCodeInReadEval: (code)->
    escaped = code.replace(/\\/g,"\\\\").replace(/"/g, "\\\"")
    if @clojureVersion?.isReaderConditionalSupported()
      "(eval (read-string {:read-cond :allow} \"#{escaped}\"))"
    else
      "(eval (read-string \"#{escaped}\"))"

  inlineResultHandler: (result, options)->
    # Alpha support of inline results using Atom Ink.
    if @ink && options.inlineOptions && atom.config.get('proto-repl.showInlineResults')

      ## TODO use makeInlineHandler for this
      io = options.inlineOptions
      if result.value
        toplevelValue = result.value
        if toplevelValue.length > 50
          toplevelValue = toplevelValue.substr(0, 50) + "..."
        prettyPrinted = protoRepl.prettyEdn(result.value).trim()
        if prettyPrinted == toplevelValue
          tree = [toplevelValue]
        else
          tree = [toplevelValue, [prettyPrinted]]
      else
        tree = [result.error]

      view = @ink.tree.treeView(tree[0], tree.slice(1), {})
      new @ink.Result io.editor, [io.range.start.row, io.range.end.row],
        content: view

  appendingResultHandler: (result, options)->
    if result.error
      @appendText("=> " + result.error)
    else if atom.config.get("proto-repl.autoPrettyPrint")
        @appendText("=>\n" + protoRepl.prettyEdn(result.value))
    else
      @appendText("=> " + result.value)

  normalResultHandler: (result, options)->
    @appendingResultHandler(result, options)
    @inlineResultHandler(result, options)

  # Executes the given code string.
  # Valid options:
  # * resultHandler - a callback function to invoke with the value that was read.
  #   If this is passed in then the value will not be displayed in the REPL.
  # * displayCode - Code to display in the REPL. This can be used when the code
  # executed is wrapped in eval or other code that shouldn't be displayed to the
  # user.
  executeCode: (code, options={})->
    return null unless @running()

    # Wrap code in read eval to handle invalid code and reader conditionals
    code = @wrapCodeInReadEval(code)

    # If a handler is supplied use that otherwise use the default.
    resultHandler = options?.resultHandler
    handler = (result)=>
      if resultHandler
        resultHandler(result, options)
      else
        @normalResultHandler(result, options)

    if options.displayCode && atom.config.get('proto-repl.displayExecutedCodeInRepl')
      @appendText(options.displayCode)

    @sendToRepl code, (result)=>
      # check if it's an extension response
      if result.value && result.value.match(/\[\s*:proto-repl-code-execution-extension/)
        parsed = window.protoRepl.parseEdn(result.value)
        extensionName = parsed[1]
        data = parsed[2]
        extensionCallback = @codeExecutionExtensions[extensionName]
        if extensionCallback
          extensionCallback(data)
      handler(result)

  # Executes the text that was entered in the entry area
  executeEnteredText: ->
    return null unless @running()
    if editor = atom.workspace.getActiveTextEditor()
      if editor == @replTextEditor.textEditor
        code = @replTextEditor.enteredText()
        @replTextEditor.clearEnteredText()
        @replHistory.setLastTextAndAddNewEntry(code)
        # Wrap code in do block so that multiple statements entered at the REPL
        # will execute all of them
        @executeCode("(do #{code})", displayCode: code)

  exit: ->
    return null unless @running()
    @appendText("Stopping REPL")
    @sendToRepl(EXIT_CMD)
    @conn = null

  interrupt: ->
    return null unless @running()
    @conn.interrupt @session, (err, result)=>
      @appendText("interrupted")

  clear: ->
    @replTextEditor.clear()
