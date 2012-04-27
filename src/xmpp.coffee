Robot   = require('hubot').robot()
Adapter = require('hubot').adapter()
Xmpp    = require 'node-xmpp'
util    = require 'util'

class XmppBot extends Adapter
  run: ->
    self = @

    options =
      username: process.env.HUBOT_XMPP_USERNAME
      password: process.env.HUBOT_XMPP_PASSWORD
      host: process.env.HUBOT_XMPP_HOST
      port: process.env.HUBOT_XMPP_PORT
      rooms:    @parseRooms process.env.HUBOT_XMPP_ROOMS.split(',')
      keepaliveInterval: 30000 # ms interval to send whitespace to xmpp server

    @robot.logger.info util.inspect(options)

    @client = new Xmpp.Client
      jid: options.username
      password: options.password
      host: options.host
      port: options.port

    @client.on 'error', @.error
    @client.on 'online', @.online
    @client.on 'stanza', @.read

    @options = options

  error: (error) =>
    @robot.logger.error error.toString()

  online: =>
    @robot.logger.info 'Hubot XMPP client online'

    @client.send new Xmpp.Element('presence', type: 'available' )
      .c('show').t('chat')

    # join each room
    # http://xmpp.org/extensions/xep-0045.html for XMPP chat standard
    for room in @options.rooms
      @client.send do =>
        el = new Xmpp.Element('presence', to: "#{room.jid}/#{@robot.name}" )
        x = el.c('x', xmlns: 'http://jabber.org/protocol/muc' )
        x.c('history', seconds: 1 ) # prevent the server from confusing us with old messages
                                    # and it seems that servers don't reliably support maxchars
                                    # or zero values
        if (room.password) then x.c('password').t(room.password)
        return x

    # send raw whitespace for keepalive
    setInterval =>
      @client.send ' '
    , @options.keepaliveInterval

    @emit 'connected'

  parseRooms: (items) ->
    rooms = []
    for room in items
      index = room.indexOf(':')
      rooms.push
        jid:      room.slice(0, if index > 0 then index else room.length)
        password: if index > 0 then room.slice(index+1) else false
    return rooms

  read: (stanza) =>
    if stanza.attrs.type is 'error'
      @robot.logger.error '[xmpp error]' + stanza
      return

    switch stanza.name
      when 'message'
        @readMessage stanza
      when 'presence'
        @readPresence stanza

  readMessage: (stanza) =>
    # ignore non-messages
    return if stanza.attrs.type not in ['groupchat', 'direct', 'chat']

    # ignore empty bodies (i.e., topic changes -- maybe watch these someday)
    body = stanza.getChild 'body'
    return unless body

    message = body.getText()

    [room, from] = stanza.attrs.from.split '/'

    # ignore our own messages in rooms
    return if from == @robot.name or from == @options.username or from is undefined

    # note that 'from' isn't a full JID, just the local user part
    user = @userForId from
    user.type = stanza.attrs.type
    user.room = room

    @receive new Robot.TextMessage user, message

  readPresence: (stanza) =>
    jid = new Xmpp.JID(stanza.attrs.from)
    bareJid = jid.bare().toString()

    # xmpp doesn't add types for standard available mesages
    # note that upon joining a room, server will send available
    # presences for all members
    # http://xmpp.org/rfcs/rfc3921.html#rfc.section.2.2.1
    stanza.attrs.type ?= 'available'

    # Parse a stanza and figure out where it came from.
    getFrom = (stanza) =>
      if bareJid not in @options.rooms
        from = stanza.attrs.from
      else
        # room presence is stupid, and optional for some anonymous rooms
        # http://xmpp.org/extensions/xep-0045.html#enter-nonanon
        from = stanza.getChild('x', 'http://jabber.org/protocol/muc#user')?.getChild('item')?.attrs?.jid
      return from

    switch stanza.attrs.type
      when 'subscribe'
        @robot.logger.debug "#{stanza.attrs.from} subscribed to us"

        @client.send new Xmpp.Element('presence',
            from: stanza.attrs.to
            to:   stanza.attrs.from
            id:   stanza.attrs.id
            type: 'subscribed'
        )
      when 'probe'
        @client.send new Xmpp.Element('presence',
            from: stanza.attrs.to
            to:   stanza.attrs.from
            id:   stanza.attrs.id
        )
      when 'available'
        # for now, user IDs and user names are the same. we don't
        # use full JIDs as user ID, since we don't get them in
        # standard groupchat messages
        from = getFrom(stanza)
        return if not from?

        [room, from] = from.split '/'

        # ignore presence messages that sometimes get broadcast
        return if not @messageFromRoom room

        # If the presence is from us, track that.
        # Xmpp sends presence for every person in a room, when join it
        # Only after we've heard our own presence should we respond to 
        # presence messages.
        if from == @robot.name or from == @options.username
          @heardOwnPresence = true
          return

        return unless @heardOwnPresence

        @robot.logger.debug "Availability received for #{from}"

        user = @userForId from, room: room, jid: jid.toString()
        @receive new Robot.EnterMessage user

      when 'unavailable'
        from = getFrom(stanza)

        [room, from] = from.split '/'

        # ignore presence messages that sometimes get broadcast
        return if not @messageFromRoom room

        # ignore our own messages in rooms
        return if from == @robot.name or from == @options.username

        @robot.logger.debug "Unavailability received for #{from}"

        user = @userForId from, room: room, jid: jid.toString()
        @receive new Robot.LeaveMessage(user)

  # Checks that the room parameter is a room the bot is in.
  messageFromRoom: (room) ->
    for joined in @options.rooms
      return true if joined.jid == room
    return false

  # Strings can be either simple strings or objects. If object is passed, it should contain two keys:
  # { 'body' : 'simple body', 'html_body' : '<span style="color:#ff0000;">body with formating!</span>' }
  send: (user, strings...) ->
    for str in strings
      @robot.logger.debug "Sending to #{user.room}: #{str}"

      params =
        to: if user.type in ['direct', 'chat'] then "#{user.room}/#{user.id}" else user.room
        type: user.type or 'groupchat'
        from: @options.username

      message = new Xmpp.Element('message', params)

      if str.constructor.name == 'Object'
        body = message
          .c('body').t(str.body).up()
          .cnode
            write: (writer) ->
              writer('<html xmlns="http://www.w3.org/1999/xhtml"><body>')
              writer(str.html_body)
              writer('</body></html>')
      else
        message.c('body').t(str)

      @client.send message

  reply: (user, strings...) ->
    for str in strings
      @send user, "#{user.name}: #{str}"

  topic: (user, strings...) ->
    string = strings.join "\n"

    message = new Xmpp.Element('message',
                to: user.room
                type: user.type
              ).
              c('subject').t(string)

    @client.send message

exports.use = (robot) ->
  new XmppBot robot

