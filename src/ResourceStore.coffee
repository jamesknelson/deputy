invariant = require('invariant')
Kefir = require('kefir')
Immutable = require('immutable')
util = require('./util')



AdapterEventListeners = [
  'opSyncSucceeded'
  'fetchRequested'
  'emptyWasReceived'
  'dataWasReceived'
  'fetchEnded'
  'opSyncFailed'
  'opSyncSucceeded'
]

Transitions =
  invalidate:
    current : "old"
    empty: "old"
  fetchRequested:
    empty: "retrieving"
    unknown: "retrieving"
    current: "refreshing"
    old: "refreshing"
  emptyWasReceived:
    old: "empty"
    unknown: "empty"
    retrieving: "empty"
    refreshing: "empty"
  dataWasReceived:
    old: "current"
    empty: "current"
    unknown: "current"
    retrieving: "current"
    refreshing: "current"
  fetchEnded:
    retrieving: "unknown"
    refreshing: "current"

OpRecord = Immutable.Record(
  state: "fresh"
  data: Immutable.Map()
  error: null
  detail: null
)

BaseRecord = Immutable.Record(
  id: null
  masterState: "unknown"
  masterSerial: null
  masterReceivedAt: null
  masterData: Immutable.Map()
  ops: Immutable.Map()
  deputyData: Immutable.Map()
)

class ResourceRecord extends BaseRecord
  transition: (eventType) ->
    if nextState = Transitions[eventType][@masterState]
      @set('masterState', nextState)
    else
      this

  set: (property, value) ->
    super(property, value)
    super('deputyData', @_getDeputyData()) if property in ["ops", "masterData"]
    this

  _getDeputyData: ->
    @masterData.merge(@ops.reduce(
      (reduced, op) -> reduced.merge(op.data)
      Immutable.Map()
    ))



class Resource
  constructor: (type, typeSchema, typeAdapter)  ->
    invariant(typeSchema, "`typeSchema` must exist")
    invariant(typeAdapter, "`typeAdapter` must exist")

    @masterDataChanges = Kefir.bus()
    @deputyDataChanges = Kefir.bus()
    
    @_type = type
    @_typeSchema = typeSchema
    @_models = {}
    @_get = typeAdapter.getter(['id'])

    for eventType in AdapterEventListeners
      handler = if eventType[0..4] == "fetch" then @_onFetchEvent else @_onDataEvent
      typeAdapter[eventType].onValue(handler.bind(this, eventType))


  getModel: (id, fetchIncomplete=true) ->
    invariant(@_get or !fetchIncomplete, "a getter must exist for this resource if fetchIncomplete is not manually set to false")
    invariant(typeof(id) == "string", "id must be a string")

    # Need to run this before we check the state, in case this id isn't
    # initialized yet
    @_ensureModelIsBuilt(id)

    state = @_models[id].get().masterState
    @_get(id) if state in ["unknown", "empty", "old"] and fetchIncomplete
    @_models[id]
      

  getRecord: (id) ->
    @_models[id].get()


  # Return a stream for a new empty resource which can be updated as required
  getEmptyModel: ->
    id = util.generateRandomUUID()
    @_ensureModelIsBuilt(id, "empty")
    @getModel(id, false)


  # Notify the resource system that the indicated ids are known to have changed
  # as of the given serial number
  # Note: currently the serial number is being passed in, but isn't actually
  # being used.
  invalidate: (ids, serial) ->
    for id in ids
      @_models[id].update (record) -> record.transition("invalidate")

    @_resourceFetcher(ids)


  _ensureModelIsBuilt: (id, state="unknown") ->
    @_models[id] ?= Kefir.model(new ResourceRecord({id, state}), Immutable.is)


  _onFetchEvent: (eventType, event) ->
    # Only mark resources which we *know* are fetching as doing so, otherwise
    # we'd end up marking every resource as fetching any time we grab an index
    if event.where.id
      ids = util.arrayWrap(event.where.id)
      for id in ids
        @_ensureModelIsBuilt(id)
        @_models[id].update (record) -> record.transition(eventType)


  _onDataEvent: (eventType, event) ->
    id = event.id

    if eventType == "emptyWasReceived"
      event.data = Immutable.Map()
    
    @_ensureModelIsBuilt(id)

    oldRecord = @_models[id].get()
    mutRecord = oldRecord.asMutable()

    switch eventType
      when "dataWasReceived", "emptyWasReceived"
        mutRecord.transition(eventType)
        mutRecord.set('masterData', event.data)
        mutRecord.set('masterSerial', event.serial)
        mutRecord.set('masterReceivedAt', event.timestamp)

      when "opPerformed"
        mutRecord.setIn(['ops', event.opId], state: 'fresh')

      when "opSyncRequested"
        changes = Immutable.Map()
        isEmpty = oldRecord.masterState == "empty"

        # Check invariants (if we can't add data to the local store, we can't
        # sync it either :D)
        for prop, value of event.data
          propertyInfo = @_typeSchema.properties.get(prop)
          invariant propertyInfo,
            "Operated properties must be defined in a propset"
          invariant propertyInfo.constant or (isEmpty and oldRecord.ops.size == 0),
            "Constant properties can only be operated on when the resource is empty"

        # Create one operation for each propset
        mutRecord.setIn(['ops', event.opId], new OpRecord(data: event.data))

      when "opSyncFailed"
        mutRecord.setIn(['ops', event.opId],
          state: 'error'
          error: event.error
          detail: event.detail
        )

      when "opSyncSucceeded"
        mutRecord.removeIn(['ops', event.opId])

      when "opReverted"
        invariant mutRecord.getIn(['ops', event.opId, 'state']) != "inflight",
          "Reverted operations cannot be inflight"
        mutRecord.removeIn(['ops', event.opId])

    newRecord = mutRecord.asImmutable()

    # Send updates on our global update buses
    if !Immutable.is(oldRecord.masterData, newRecord.masterData)
      @masterDataChanges.emit(newRecord)

    if !Immutable.is(oldRecord.deputyData, newRecord.deputyData)
      @deputyDataChanges.emit(newRecord)

    # Update the model for this id
    @_models[id].set(newRecord)



module.exports = class ResourceStore
  constructor: (schema, adapter) ->
    for type in schema.types
      this[type] = new Resource(type, schema[type], adapter[type])
