SecretSauce =
  mixin: (module, klass) ->
    for key, fn of @[module]
      klass.prototype[key] = fn

SecretSauce.Keys =
  _convertToId: (index) ->
    ival = index.toString(36)
    ## 0 pad number to ensure three digits
    [0,0,0].slice(ival.length).join("") + ival

  _getProjectKeyRange: (id) ->
    @cache.getProject(id).get("RANGE")

  ## Lookup the next Test integer and update
  ## offline location of sync
  getNextTestNumber: (projectId) ->
    @_getProjectKeyRange(projectId)
    .then (range) =>
      return @_getNewKeyRange(projectId) if range.start is range.end

      range.start += 1
      range
    .then (range) =>
      range = JSON.parse(range) if SecretSauce._.isString(range)
      @cache.updateRange(projectId, range)
      .return(range.start)

  nextKey: ->
    @project.ensureProjectId().bind(@)
    .then (projectId) ->
      @cache.ensureExists().bind(@)
      .then -> @cache.ensureProject(projectId)
      .then -> @getNextTestNumber(projectId)
      .then @_convertToId

SecretSauce.Socket =
  leadingSlashes: /^\/+/

  onTestFileChange: (filepath, stats) ->
    ## simple solution for preventing firing test:changed events
    ## when we are making modifications to our own files
    return if @app.enabled("editFileMode")

    ## strip out our testFolder path from the filepath, and any leading forward slashes
    filepath      = filepath.split(@app.get("cypress").projectRoot).join("").replace(@leadingSlashes, "")
    strippedPath  = filepath.replace(@app.get("cypress").testFolder, "").replace(@leadingSlashes, "")

    @io.emit "generate:ids:for:test", filepath, strippedPath

  _startListening: (chokidar, path, fs) ->
    { _ } = SecretSauce

    @io.on "connection", (socket) =>
      console.log "socket connected"

      socket.on "generate:test:id", (data, fn) =>
        console.log("generate:test:id", data)
        @idGenerator.getId(data)
        .then(fn)
        .catch (err) ->
          console.log "\u0007", err.details, err.message
          fn(message: err.message)

      socket.on "finished:generating:ids:for:test", (strippedPath) =>
        console.log "finished:generating:ids:for:test", strippedPath
        @io.emit "test:changed", file: strippedPath

      _.each "load:iframe command:add runner:start runner:end before:run before:add after:add suite:add suite:start suite:stop test test:add test:start test:end after:run test:results:ready exclusive:test".split(" "), (event) ->
        socket.on event, (args...) =>
          args = _.chain(args).compact().reject(_.isFunction).value()
          @io.emit event, args...

      ## when we're told to run:sauce we receive
      ## the spec and callback with the name of our
      ## sauce labs job
      ## we'll embed some additional meta data into
      ## the job name
      socket.on "run:sauce", (spec, fn) =>
        ## this will be used to group jobs
        ## together for the runs related to 1
        ## spec by setting custom-data on the job object
        batchId = Date.now()

        jobName = @app.get("cypress").testFolder + "/" + spec
        fn(jobName, batchId)

        ## need to handle platform/browser/version incompatible configurations
        ## and throw our own error
        ## https://saucelabs.com/platforms/webdriver
        jobs = [
          { platform: "Windows 8.1", browser: "internet explorer",  version: 11 }
          { platform: "Windows 7",   browser: "internet explorer",  version: 10 }
          { platform: "Linux",       browser: "chrome",             version: 37 }
          { platform: "Linux",       browser: "firefox",            version: 33 }
          { platform: "OS X 10.9",   browser: "safari",             version: 7 }
        ]

        normalizeJobObject = (obj) ->
          obj = _(obj).clone()

          obj.browser = {
            "internet explorer": "ie"
          }[obj.browserName] or obj.browserName

          obj.os = obj.platform

          _(obj).pick "name", "browser", "version", "os", "batchId", "guid"

        _.each jobs, (job) =>
          options =
            host:        "0.0.0.0"
            port:        @app.get("port")
            name:        jobName
            batchId:     batchId
            guid:        uuid.v4()
            browserName: job.browser
            version:     job.version
            platform:    job.platform

          clientObj = normalizeJobObject(options)
          socket.emit "sauce:job:create", clientObj

          df = jQuery.Deferred()

          df.progress (sessionID) ->
            ## pass up the sessionID to the previous client obj by its guid
            socket.emit "sauce:job:start", clientObj.guid, sessionID

          df.fail (err) ->
            socket.emit "sauce:job:fail", clientObj.guid, err

          df.done (sessionID, runningTime, passed) ->
            socket.emit "sauce:job:done", sessionID, runningTime, passed

          sauce options, df

    watchTestFiles = chokidar.watch path.join(@app.get("cypress").projectRoot, @app.get("cypress").testFolder), ignored: (path, stats) ->
      ## this fn gets called twice, once with the directory
      ## which does not have a stats argument
      ## we always return false to include directories
      ## until we implement ignoring specific directories
      return false if fs.statSync(path).isDirectory()

      ## else if this is a file make sure its ignored if its not
      ## a js or coffee files
      not /\.(js|coffee)$/.test path

    watchTestFiles.on "change", _.bind(@onTestFileChange, @)

    ## BREAKING DUE TO __DIRNAME
    # watchCssFiles = chokidar.watch path.join(__dirname, "public", "css"), ignored: (path, stats) ->
    #   return false if fs.statSync(path).isDirectory()

    #   not /\.css$/.test path

    # # watchCssFiles.on "add", (path) -> console.log "added css:", path
    # watchCssFiles.on "change", (filepath, stats) =>
    #   filepath = path.basename(filepath)
    #   @io.emit "eclectus:css:changed", file: filepath

SecretSauce.IdGenerator =
  reSymbols: /[-\/\\^$*+?.()|[\]{}]/g

  hasExistingId: (e) ->
    e.idFound

  idFound: ->
    e = new Error
    e.idFound = true
    throw e

  escapeRegExp: (str) ->
    str.replace(@reSymbols, '\\$&');

  nextId: (data) ->
    @keys.nextKey().bind(@)
    .then((id) ->
      @appendTestId(data.spec, data.title, id)
      .return(id)
    )
    .catch (e) ->
      @logErr(e, data.spec)

      throw e

  appendTestId: (spec, title, id) ->
    normalizedPath = @path.join(@projectRoot, spec)

    @read(normalizedPath).bind(@)
    .then (contents) ->
      @insertId(contents, title, id)
    .then (contents) ->
      ## enable editFileMode which prevents us from sending out test:changed events
      @editFileMode(true)

      ## write the new content back to the file
      @write(normalizedPath, contents)
    .then ->
      ## remove the editFileMode so we emit file changes again
      ## if we're still in edit file mode then wait 1 second and disable it
      ## chokidar doesnt instantly see file changes so we have to wait
      @editFileMode(false, {delay: 1000})
    .catch @hasExistingId, (err) ->
      ## do nothing when the ID is existing

  insertId: (contents, title, id) ->
    re = new RegExp "['\"](" + @escapeRegExp(title) + ")['\"]"

    # ## if the string is found and it doesnt have an id
    matches = re.exec contents

    ## matches[1] will be the captured group which is the title
    return @idFound() if not matches

    ## position is the string index where we first find the capture
    ## group and include its length, so we insert right after it
    position = matches.index + matches[1].length + 1
    @str.insert contents, position, " [#{id}]"

module?.exports = SecretSauce