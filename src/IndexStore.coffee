# # Index
#
# Each instance of the index class keeps indexes of both the master and
# deputy records. This allows us to easily and accurately detect deindexing
# of records by remote clients, even when the deindexed records have been
# modified locally.



invariant = require('invariant')
capitalize = require('./util').capitalize
Kefir = require('kefir')
Immutable = require('immutable')



Transitions =
  fetchRequested:
    complete: "refreshing"
    incomplete: "retrieving"
  indexWillBeReceived:
    complete: "processing"
    incomplete: "processing"
    refreshing: "processing"
    retrieving: "processing"
  indexWasReceived:
    processing: "complete" 
  fetchEnded:
    retrieving: "incomplete"
    refreshing: "complete"

BaseRecord = Immutable.Record(
  id: null
  state: "incomplete"
  masterSerial: null
  masterIds: Immutable.Set()
  deputyIds: Immutable.Set()
) 

class IndexRecord extends BaseRecord
  transition: (eventType) ->
    if nextState = Transitions[eventType][@state]
      @set('state', nextState)
    else
      this



class Index
  constructor: (typeSchema, typeAdapter, typeResource, definition)  ->
    invariant(typeSchema, "`typeSchema` must exist")
    invariant(typeAdapter, "`typeAdapter` must exist")
    invariant(typeResource, "`typeResource` must exist")

    @_where = definition.where or {}
    @_whereProperties = Object.keys(@_where)
    @_allProperties =
      if definition.key
        @_whereProperties.concat(definition.key)
      else
        @_whereProperties

    versionedProperties = Object.keys(typeSchema.properties
      .filter (info, prop) => (prop in @_allProperties) and !info.constant
      .toJS()
    )

    invariant(versionedProperties.length <= 1, "You cannot index more than one versioned property")

    @_keyProperty = definition.key
    @_versionedProperty = versionedProperties[0]

    @_typeResource = typeResource

    @_models = {}

    # Generate a function which extracts an index key from the supplied data
    @_key = (data) =>
      data and
      @_whereProperties.every((prop) => data.get(prop) == @_where[prop]) and
      (!@_keyProperty or data.get(@_keyProperty))

    # Attempt to generate a function to fetch the index
    @_get = if definition.key
      typeAdapter.getter([definition.key], @_where)
    else
      typeAdapter.getter([], @_where)

    # Generate functions to update the indexes based on resource changes
    @_reindexMaster = @_reindexerFactory('master')
    @_reindexDeputy = @_reindexerFactory('deputy')

    typeResource.masterDataChanges.onValue(@_onResourceMasterDataChange.bind(this))
    typeResource.deputyDataChanges.onValue(@_onResourceDeputyDataChange.bind(this))

    for eventType in Object.keys(Transitions)
      typeAdapter[eventType].onValue(@_onAdapterEvent.bind(this, eventType))


  getModel: (id=true, fetchIncomplete=true) ->
    invariant @_get or !fetchIncomplete,
      "a getter must exist for this index if fetchIncomplete is not manually set to false"
    invariant (!@_keyProperty and id == true) or (@_keyProperty and typeof(id) == "string"),
      "id must be a string if not a singleton, or true otherwise"

    @_ensureModelIsBuilt(id)

    state = @_models[id].get().state
    @_get(id) if state == "incomplete" and fetchIncomplete
      
    return @_models[id].filter (record) -> record.state != "processing"


  _ensureModelIsBuilt: (id) ->
    @_models[id] ?= Kefir.model(new IndexRecord({id}), Immutable.is)


  # Generate reindexing methods for both types of index in one place, as the
  # logic doesn't change between them.
  _reindexerFactory: (type) ->
    previousIds = {}
    dataPath = "#{type}Data"
    idsPath = ["#{type}Ids"]

    (resource) ->
      id = resource.id

      newIndexId = @_key(resource[dataPath])
      oldIndexId = previousIds[id]

      if oldIndexId and oldIndexId != newIndexId
        @_models[oldIndexId].update (r) ->
          r.updateIn(idsPath, (s) -> s.delete(id))

      if !oldIndexId or oldIndexId != newIndexId
        @_ensureModelIsBuilt(newIndexId)
        @_models[newIndexId].update (r) ->
          r.updateIn(idsPath, (s) -> (s ? Immutable.Set()).add(id))

      previousIds[id] = newIndexId


  _onResourceMasterDataChange: (resource) ->
    # PERF: disable while index is in processing state, and instead add all
    # received ids in one go at data-was-received
    @_reindexMaster(resource)


  _onResourceDeputyDataChange: (resource) ->
    @_reindexDeputy(resource)


  _onAdapterEvent: (eventType, event) ->
    eventWhereProperties = Object.keys(event.where)
    matchingConditions =
      eventWhereProperties.length == @_allProperties.length and
      eventWhereProperties.every((prop) =>
        prop == @_keyProperty or
        (prop in @_whereProperties and event.where[prop] == @_where[prop])
      )

    # Only process events whose conditions match the index's conditions
    if matchingConditions
      id = if @_keyProperty then event.where[@_keyProperty] else true

      @_ensureModelIsBuilt(id)

      @_models[id].update (record) =>
        record.withMutations (record) =>
          record.transition(eventType)

          if eventType == "indexWasReceived"
            record.set('masterSerial', event.serial)

            # If records have been deindexed by a different client, they won't
            # appear in our list, and we must remove them.
            outOfDateMasterIds = record.masterIds
              .subtract(event.index)
              .filter((id) => @resource.getRecord(id).masterSerial < event.serial)

            # If any of the properties on the index are versionable (and thus
            # can be patched), some of the removed records may have a pending
            # operation to add them back in locally, and would thus still be
            # in the deputy index.
            outOfDateDeputyIds =
              if !@_versionedProperty
                outOfDateMasterIds
              else
                outOfDateMasterIds.filter (id) =>
                  {masterData, deputyData} = @resource.getRecord(id)
                  versionedPropValue = deputyData[@_versionedProperty]

                  masterData == deputydata or
                  (propertyType == Index.Key and versionedPropData != id) or
                  (propertyType == Index.Blacklist and versionedPropData)

            @_resourceInvalidator? outOfDateMasterIds

            record.updateIn ['masterIds'], (ids) ->
              (ids ? Immutable.Set()).subtract(outOfDateMasterIds)

            record.updateIn ['deputyIds'], (ids) ->
              (ids ? Immutable.Set()).subtract(outOfDateDeputyIds)



module.exports = class IndexStore
  constructor: (schema, adapter, resourceStore, definition) ->
    for index, indexDefinition of definition
      type = indexDefinition.type
      delete indexDefinition.type

      invariant schema[type],
        "An index's `type` must exist in the passed in schema"

      this[index] = new Index(
        schema[type]
        adapter[type]
        resourceStore[type]
        indexDefinition
      )
