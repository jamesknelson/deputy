# Descriptors specify how JSON can be constructed and deconstructed from 
# resources and indexes, and the relationships between them.
#
# To define a descriptor, a javascript object is passed in which is comprised
# of some of the following:
#
# - `resource`: A deputy resource
# - `collection`:  A deputy index, which in the JSON contains embedded
#   resources
# - `order`: A comparison function to use to order resources in a collection
# - `embed`: Embed associated objects using the given descriptor
# - `idProperty`: *Used in embedded descriptors only.* Attribute specifying
#   the property in the parent object whose value will be used as the resource
#   or index id for the embedded descriptor. When not specified, the following
#   defaults will be used:
#
#   * Collection: use `id`
#   * Resource: use the embedded property name, without leading `$`, and with
#     `Id` appended
#
# Example where given `idProperty` values match the default ones:
#
# ```
# descriptor = new Deputy.Descriptor
#   resource: Resources.Contact
#   embed:
#     cards:
#       collection: Indexes.ContactCards
#       idProperty: 'id'
#       $question:
#         resource: Resources.Question
#         idProperty: 'questionId'
#     photos:
#       collection: Indexes.ContactPhotos
#       idProperty: 'id'
# ```


Immutable = require("immutable")
invariant = require("invariant")
Kefir = require("kefir")



getDefaultIdProperty = (embed, embedDefinition) ->
  if embedDefinition.collection
    'id'
  else
    embed.substr(1)+'Id'



class Descriptor
  constructor: (definition) ->
    invariant(definition.collection or definition.resource, "A descriptor must have either a collection or resource at the root level")
    
    Object.assign(this, definition)

    if definition.embed
      @_embedDescriptors = {}
      for embed, embedDefinition of definition.embed
        embedDefinition.idProperty ?= getDefaultIdProperty(embed, embedDefinition)
        @_embedDescriptors[embed] = new Descriptor(embedDefinition)


  # Emit a stream of events based on the descriptor starting with this id
  getModel: (id) ->
    if @collection
      @collection
        .getModel(id)
        .flatMap (index) =>
          indexIds = index.deputyIds.toArray()
          # TODO: add index metadata (state, etc.)
          if indexIds.length
            Kefir.combine(
              indexIds.map (id) =>
                @collection._typeResource
                  .getModel(id)
                  .flatMap(@_embeddedResourcesProperty.bind(this))
              (args...) =>
                unsorted = Immutable.List(args)
                if @order
                  unsorted.sort(@order)
                else
                  unsorted
            )
          else
            Kefir.constant(Immutable.List())

    else if @resource
      @resource
        .getModel(id)
        .flatMap(@_embeddedResourcesProperty.bind(this))


  _embeddedResourcesProperty: (resource) ->
    if @_embedDescriptors
      names = []
      properties = []
      for embed, descriptor of @_embedDescriptors
        names.push(embed)
        properties.push(descriptor.getModel(resource[descriptor.idProperty]))

      combinator = (args...) ->
        combined = Immutable.Map(resource.entries()).asMutable()
        for value, i in args
          combined.set(names[i], value)
        combined.asImmutable()

      Kefir.combine(properties, combinator)

    else
      Kefir.constant(resource)



module.exports = Descriptor