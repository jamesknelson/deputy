exports.generateRandomUUID = ->
  'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, uuidReplacer)


uuidReplacer = (c) ->
    r = Math.random()*16|0
    v = c == 'x' ? r : (r&0x3|0x8)
    v.toString(16)


# ---


exports.capitalize = (string) ->
  string.charAt(0).toUpperCase() + string.slice(1)


# ---


exports.arrayWrap = (x) ->
  if Array.isArray(x) then x else [x]
