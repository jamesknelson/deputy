# # Adapter
#
# Adapters are charged with maintaining a list of remote endpoints which can
# be called to fetch data or perform operations. 
#
# The adapater can be queried for relevant endpoints with
# `getEndpoint(type, parameters, conditions)`, which returns the first
# matching endpoint, or null if none exists.
#
# The adapter builds event firehoses for each type listed inthe sschema,
# emitting the following events:
#
# - type.fetchRequested (where)
# - type.fetchEnded (where)
#
# - type.indexWillBeReceived (serial, where)
# - type.emptyWasReceived (serial, id)
# - type.dataWasReceived (serial, id, data)
# - type.indexWasReceived (serial, where, index)
#
# - type.opRequested (id, opId, data)
# - type.opFailed (id, opId, error)
# - type.opSucceeded (id, opId)



util = require('./util')
invariant = require('invariant')
Immutable = require('immutable')
Kefir = require('kefir')



EventTypes = [
  'fetchRequested'
  'opSyncRequested'
  'indexWillBeReceived'
  'emptyWasReceived'
  'dataWasReceived'
  'indexWasReceived'
  'fetchEnded'
  'opSyncFailed'
  'opSyncSucceeded'
]



class Adapter
  @apiRequest = null


  constructor: (@_schema) ->
    invariant(Adapter.apiRequest, "An apiRequest method must be set at `Adapter.apiRequest`")

    for type in @_schema.types
      this[type] = new TypeAdapter(this, type)


  # Process [JSON API](http://jsonapi.org/format/) format
  _processData: (requestedType, where, data) ->
    receivedResources = []

    for type, typeResources of data.linked when @_schema[type]
      for resource in typeResources
        resource.type = type
        receivedResources.push(resource)

    meta = data.meta ? {}
    meta.timestamp = new Date(meta.fetchedAt)

    delete data.meta
    delete data.links
    delete data.linked

    # Set the main resources last so they won't be emitted until all their
    # linked dependencies have been
    mainType = Object.keys(data)[0]
    mainResources = util.arrayWrap(data[mainType])

    for resource in mainResources
      resource.type = mainType
      receivedResources.push(resource)

    invariant Object.keys(data).length == 1,
      "There should be exactly one type of resource on the responsoe root"
    invariant mainType == requestedType,
      "The received type must match the requested type"
    invariant meta.serial,
      "The received resource must have a `serial` meta property"

    # Build a list of embedded indexes
    receivedIndexes = []
    for resource in receivedResources when resource.links
      for associationName, index of resource.links
        if association = @_schema[resource.type].associations.get(associationName)
          indexWhere = Object.assign({}, association.where)
          indexWhere[association.foreignKey] = resource.id
          receivedIndexes.push(
            type: association.many ? association.one
            where: indexWhere
            index: index
          )

      delete resource.links
      delete resource.href

    # If this endpoint was itself an index, add this as the first index (which
    # will be the final index to have `indexWasReceived` emitted)
    if !where.id
      receivedIndexes.unshift(
        type: mainType
        where: where
        index: mainResources.map (r) -> r.id
      )

    # Emit our events in the correct order
    for index in receivedIndexes
      this[index.type].indexWillBeReceived.emit(
        where: index.where
        serial: meta.serial
      )

    for resource in receivedResources
      if Object.keys(resource).length == 2
        this[resource.type].emptyWasReceived.emit(
          serial: meta.serial
          id: resource.id
        )
      else
        this[resource.type].dataWasReceived.emit(
          serial: meta.serial
          timestamp: meta.timestamp
          id: resource.id
          data: Immutable.fromJS(resource)
        )

    receivedIndexes.reverse()
    for index in receivedIndexes
      this[index.type].indexWasReceived.emit(
        where: index.where
        serial: meta.serial
        timestamp: meta.timestamp
        index: Immutable.Set(index.index)
      )



class TypeAdapter
  constructor: (@_adapter, @_type) ->
    for eventType in EventTypes
      this[eventType] = Kefir.bus()


  getter: (parameters, constants) ->
    (args...) =>
      where = Object.assign({}, constants)
      for param, i in parameters
        where[param] = args[i]

      Adapter.apiRequest(
        method: "GET"
        url: @_url(where)
      ).done(
        (data) =>
          @_adapter._processData(@_type, where, data)
          @fetchEnded.emit({where})
        (err) =>
          @fetchEnded.emit({where})
      )

      @fetchRequested.emit({where})  


  _url: (where) ->
    base = "/#{@_type}"

    if where.id
      invariant Object.keys(where).length == 1,
        "A url with an id cannot have any filters"

      ids = util.arrayWrap(where.id).map(encodeURIComponent)

      [base, ids.join(',')].join('/')

    else
      "#{base}?" + Immutable.Map(where)
        .map (v, k) -> "#{encodeURIComponent(k)}=#{encodeURIComponent(v)}"
        .join('&')



module.exports = Adapter