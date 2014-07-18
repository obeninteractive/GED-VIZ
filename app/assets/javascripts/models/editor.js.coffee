define [
  'underscore'
  'models/base/model'
  'models/presentation'
], (_, Model, Presentation) ->
  'use strict'

  class Editor extends Model

    # Attributes
    # ----------
    #
    # The editor governs several submodels:
    # - keyframe: Working keyframe. This is not in presentation.keyframes,
    #   it might be a copy of one in presentation.keyframes.
    # - presentation
    #   - keyframes: Captured keyframes are added to this collection
    #
    # Other important attributes:
    # - index: Index of the current active keyframe

    # Property declarations
    # ---------------------
    #
    # _moveIndex: Number

    initialize: (attributes, options) ->
      super

      # Create the presentation model
      presentation = new Presentation options.presentationData, parse: true
      @set {presentation}

      # Listen for keyframe collection changes
      keyframes = presentation.get 'keyframes'
      @listenTo keyframes, 'add', @keyframeAdded
      @listenTo keyframes, 'remove', @keyframeRemoved
      @listenTo keyframes, 'reset', @keyframesResetted
      @listenTo keyframes, 'change:title', @keyframeTitleChanged

      # Pub/Sub events
      @subscribeEvent 'locking:set', @lockingSetHandler

    # Shortcut getters
    # ----------------

    getPresentation: ->
      @get 'presentation'

    # Get the working keyframe
    getKeyframe: ->
      @get 'keyframe'

    # Get the “captured” keyframes saved on the presentation
    getKeyframes: ->
      @get('presentation').get 'keyframes'

    # Start fetching the presentation
    # -------------------------------

    fetchPresentation: (fetchFromRemote) ->
      presentation = @getPresentation()

      if fetchFromRemote
        presentation.fetch()
        return

      # If the editor is started without a specific presentation ID,
      # try to load the latest working draft from localStorage
      if presentation.id is 'new'
        fetched = presentation.fetchLocally()
        return if fetched

      # Model was prefilled with data
      presentation.setSynced()

      return

    # Save the current working draft
    # ------------------------------

    saveDraft: ->
      # Create a presentation copy
      draft = @getPresentation().clone()
      index = @get 'index'
      draft.set {id: 'draft', index}
      # Add the working keyframe if it differs from existing keyframes
      unless index?
        # Clone without the data
        keyframe = @getKeyframe().clone withData: false
        draft.getKeyframes().add keyframe
      # Save
      draft.saveLocally()
      return

    # Limit calls to saveDraft
    @prototype.saveDraft = _.debounce @prototype.saveDraft, 250

    # Locking handler
    # ---------------

    lockingSetHandler: (newLocking) ->
      @getKeyframe().set locking: newLocking
      return

    # Move existing keyframes
    # -----------------------

    moveKeyframe: (oldIndex, newIndex) ->
      @_moveIndex = newIndex
      @getKeyframes().moveKeyframe(oldIndex, newIndex)
      return

    # Capture a keyframe
    # ------------------

    captureKeyframe: (attributes) ->
      keyframe = @getKeyframe()
      keyframe.set attributes
      @getKeyframes().add keyframe
      @selectKeyframe keyframe
      @publishEvent 'keyframe:capture', this
      return

    # Handlers for keyframes collection events
    # ----------------------------------------

    keyframeAdded: (keyframe, keyframes, options) ->
      index = @get 'index'

      # Fix the index when moving keyframes
      if index? and  @_moveIndex?
        @set index: @_moveIndex
        delete @_moveIndex

      @saveDraft()

      return

    keyframeRemoved: (keyframe, keyframes, options) ->
      index = @get 'index'

      if index? and options.index <= index
        # Fix the index, select the previous
        @set index: index - 1

      @saveDraft()

      return

    keyframesResetted: ->
      presentation = @getPresentation()

      if presentation.id is 'new'
        @showNewPresentation()

      else if presentation.id is 'draft'
        @showDraft()

      else
        @showExistingPresentation()

      return

    showExistingPresentation: ->
      # Presentation is an existing one from the server.
      # Select the keyframe at the known index, or just the first.
      index = @get 'index'
      keyframes = @getKeyframes()
      unless index? and 0 <= index < keyframes.length
        index = 0
      @selectKeyframe keyframes.at(index)
      return

    showNewPresentation: ->
      # Presentation is new and has only one keyframe.
      # Make this the working keyframe and remove it.
      keyframes = @getKeyframes()
      keyframe = keyframes.at 0
      keyframes.remove keyframe, silent: true
      @selectKeyframe keyframe, clone: false
      return

    showDraft: ->
      # Presentation is a draft from localStorage.

      presentation = @getPresentation()
      index = presentation.get 'index'

      keyframes = @getKeyframes()

      if index?
        # Restore keyframe selection
        keyframe = keyframes.at index

      else
        # Make the last the working keyframe and remove it.
        keyframe = keyframes.last()
        keyframes.remove keyframe, silent: true

      # Fetch all keyframes, render when the selected keyframe was fetched
      keyframes.each (keyframeToFetch) =>
        deferred = keyframeToFetch.fetch()
        if keyframeToFetch is keyframe
          deferred.then _.bind(@selectDraftKeyframe, this, keyframe, index)

      return

    selectDraftKeyframe: (keyframe, index) ->
      clone = if index? then true else false
      @selectKeyframe keyframe, {clone}
      return

    # Fetch all keyframes including the current working keyframe.
    # Returns the fetch Deferred for the current keyframe.
    fetchAllKeyframes: ->
      @getKeyframes().each (keyframe) -> keyframe.fetch()
      @getKeyframe().fetch()

    # The working keyframe was changed
    # --------------------------------

    keyframeChanged: (keyframe) ->
      @unset 'index'
      changes = keyframe.changedAttributes()
      # Don’t save when it’s just a server fetch
      @saveDraft() unless changes.elements
      return

    # A captured keyframe was changed
    # -------------------------------

    keyframeTitleChanged: ->
      @saveDraft()
      return

    # Select a keyframe, use it as the working keyframe
    # -------------------------------------------------

    selectKeyframe: (keyframe, options = {}) ->
      _.defaults options, clone: true

      oldIndex = @get 'index'
      oldKeyframe = @getKeyframe()
      index = @getKeyframes().indexOf keyframe

      # Already selected
      return if oldKeyframe and (index is oldIndex)

      # Create a clone of the keyframe
      keyframe = keyframe.clone() if options.clone

      # Setup/teardown listening for changes
      if oldKeyframe
        @stopListening oldKeyframe, 'change', @keyframeChanged
      @listenTo keyframe, 'change', @keyframeChanged

      @set {keyframe}

      if index >= 0
        @set {index}
      else
        @unset 'index'

      return

    # Disposal
    # --------

    dispose: ->
      return if @disposed
      # Dispose dependent models
      @getPresentation().dispose()
      @getKeyframe().dispose()
      super
