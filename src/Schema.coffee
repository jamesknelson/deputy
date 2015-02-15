invariant = require('invariant')
Immutable = require('immutable')



ReservedProperties = Immutable.Set(
  'id'
  'type'
  'href'
  'links'
  'state'
)



# ---------------------------------------------------------------------------



PropertyRecordBase = Immutable.Record(
  constant: false
  versionedBy: null
  foreignKey: null
)

class PropertyRecord extends PropertyRecordBase
  constructor: (args) ->
    super(args)

    invariant @versionedBy or @constant,
      "A Schema PropertyRecord must specify a `versionedBy`, or be a constant"



# ---------------------------------------------------------------------------



AssociationRecordBase = Immutable.Record(
  many: false
  one: false
  foreignKey: null
  where: {}
)

class AssociationRecord extends AssociationRecordBase
  constructor: (args) ->
    super(args)

    invariant !@where.id,
      "A Schema AssociationRecord's `where` property cannot use `id`."
    invariant !(@many and @one) and (@many or @one),
      "A Schema AssociationRecord must have `many` or `one` set to `true`, but not both."



# ---------------------------------------------------------------------------



TypeRecordBase = Immutable.Record(
  properties: Immutable.Map()
  associations: Immutable.Map()
)

class TypeRecord extends TypeRecordBase
  constructor: (args) ->
    args.properties   = Immutable.Map(args.properties).map   (p) -> new PropertyRecord(p)
    args.associations = Immutable.Map(args.associations).map (p) -> new AssociationRecord(p)

    super(args)

    invariant @properties.size > 0,
      "A Schema TypeRecord must have at least one property"

    invariant !ReservedProperties.intersect(@properties.keys()).size,
      "Your schema cannot contain reserved properties"



# ---------------------------------------------------------------------------



module.exports = class Schema
  constructor: (definition) ->
    @types = Object.keys(definition)

    for type, typeDefinition of definition
      this[type] = new TypeRecord(typeDefinition)
