package com.zarz.spotiflac

import android.content.Context
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.images.WebImage
import android.net.Uri
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.Inet4Address

class SpotiCastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions = CastOptions.Builder()
        .setReceiverApplicationId(BuildConfig.CAST_RECEIVER_APP_ID)
        .setStopReceiverApplicationWhenEndingSession(true)
        .build()
    override fun getAdditionalSessionProviders(context: Context) = null
}

/** SDK session ownership survives activity recreation; no discovery sockets in Dart. */
class SpotiCastPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingDiscovery: MethodChannel.Result? = null
    private val progressListener = RemoteMediaClient.ProgressListener { _, _ -> publishStatus() }
    private var cast: CastContext? = null
    private var router: MediaRouter? = null
    private var client: RemoteMediaClient? = null
    private var lastFinishedId: String? = null
    private val namespace = "urn:x-cast:com.spotiflac.tv"
    private val routeCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = publishRoutes()
        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = publishRoutes()
        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = publishRoutes()
    }
    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = publishStatus()
        override fun onMetadataUpdated() = publishStatus()
    }
    private val listener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, id: String) = attach(session)
        override fun onSessionResumed(session: CastSession, suspended: Boolean) = attach(session)
        override fun onSessionEnded(session: CastSession, error: Int) = detach()
        override fun onSessionStartFailed(session: CastSession, error: Int) = failed(error)
        override fun onSessionResumeFailed(session: CastSession, error: Int) = failed(error)
        override fun onSessionSuspended(session: CastSession, reason: Int) {
            emit(mapOf("type" to "suspended"))
        }
        override fun onSessionStarting(session: CastSession) { emit(mapOf("type" to "connecting")) }
        override fun onSessionResuming(session: CastSession, id: String) { emit(mapOf("type" to "connecting")) }
        override fun onSessionEnding(session: CastSession) {}
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "com.zarz.spotiflac/cast")
        events = EventChannel(binding.binaryMessenger, "com.zarz.spotiflac/cast_events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    private fun emit(value: Map<String, Any?>) { sink?.success(value) }
    private fun failed(code: Int) { emit(mapOf("type" to "error", "message" to "Cast connection failed ($code)")); detach() }
    private fun initialize() {
        if (cast != null) return
        check(BuildConfig.CAST_RECEIVER_APP_ID.isNotEmpty()) { "Custom Cast receiver is not configured in this build" }
        val instance = CastContext.getSharedInstance(context)
        cast = instance
        router = MediaRouter.getInstance(context)
        instance.sessionManager.addSessionManagerListener(listener, CastSession::class.java)
        instance.sessionManager.currentCastSession?.takeIf { it.isConnected }?.let { attach(it) }
    }
    private fun attach(session: CastSession) {
        client?.removeProgressListener(progressListener)
        client?.unregisterCallback(mediaCallback)
        client = session.remoteMediaClient
        client?.registerCallback(mediaCallback)
        client?.addProgressListener(progressListener, 500L)
        session.setMessageReceivedCallbacks(namespace) { _, _, message ->
            try {
                val json = JSONObject(message)
                if (json.optString("type") == "command" && json.optString("action") in listOf("next", "previous", "shuffle", "repeat", "favorite", "jump", "disconnect")) {
                    emit(mapOf("type" to "command", "action" to json.getString("action"), "index" to json.optInt("index", -1)))
                }
            } catch (_: Exception) {}
        }
        emit(mapOf("type" to "connected", "device" to session.castDevice?.friendlyName))
        publishStatus()
    }
    private fun detach() {
        client?.removeProgressListener(progressListener)
        client?.unregisterCallback(mediaCallback)
        client = null
        emit(mapOf("type" to "disconnected"))
    }
    private fun publishRoutes() {
        val selector = cast?.mergedSelector ?: return
        emit(mapOf("type" to "routes", "routes" to router?.routes?.filter {
            !it.isDefault && it.isEnabled && it.matchesSelector(selector)
        }?.map { mapOf("id" to it.id, "name" to it.name) }))
    }
    private fun publishStatus() {
        val remote = client ?: return
        val status = remote.mediaStatus ?: return
        val id = status.mediaInfo?.customData?.optString("mediaId")
        val finished = status.playerState == MediaStatus.PLAYER_STATE_IDLE && status.idleReason == MediaStatus.IDLE_REASON_FINISHED
        if (!finished) lastFinishedId = null
        emit(mapOf("type" to "status", "mediaId" to id,
            "positionMs" to remote.approximateStreamPosition,
            "durationMs" to remote.streamDuration,
            "playing" to (status.playerState == MediaStatus.PLAYER_STATE_PLAYING),
            "buffering" to (status.playerState == MediaStatus.PLAYER_STATE_BUFFERING),
            "volume" to status.streamVolume))
        if (finished && id != null && id != lastFinishedId) {
            lastFinishedId = id
            emit(mapOf("type" to "finished", "mediaId" to id))
        }
        if (status.playerState == MediaStatus.PLAYER_STATE_IDLE && status.idleReason == MediaStatus.IDLE_REASON_ERROR) {
            emit(mapOf("type" to "error", "message" to "The TV could not play this audio format or reach the phone"))
        }
    }
    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        try {
            if (call.method == "configured") { result.success(BuildConfig.CAST_RECEIVER_APP_ID.isNotEmpty()); return }
            if (call.method == "discover" && Build.VERSION.SDK_INT >= 37 && context.checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") != PackageManager.PERMISSION_GRANTED) {
                check(pendingDiscovery == null) { "A network permission request is already pending" }
                val host = activity ?: error("Open the app to allow local network access")
                pendingDiscovery = result
                host.requestPermissions(arrayOf("android.permission.ACCESS_LOCAL_NETWORK"), 7124)
                return
            }
            initialize()
            when (call.method) {
                "discover" -> { router?.addCallback(cast!!.mergedSelector ?: error("Cast discovery is unavailable"), routeCallback, MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY); publishRoutes(); result.success(null) }
                "stopDiscovery" -> { router?.removeCallback(routeCallback); result.success(null) }
                "connect" -> {
                    val route = router?.routes?.firstOrNull { it.id == call.argument<String>("id") }
                        ?: error("The selected TV is no longer available")
                    router?.selectRoute(route); result.success(null)
                }
                "disconnect" -> { cast!!.sessionManager.endCurrentSession(true); result.success(null) }
                "localAddress" -> {
                    val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val network = cm.activeNetwork ?: error("Connect the phone and TV to the same Wi-Fi network")
                    val caps = cm.getNetworkCapabilities(network)
                    check(caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true || caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true) { "Casting local music requires Wi-Fi or Ethernet" }
                    val address = cm.getLinkProperties(network)?.linkAddresses?.map { it.address }?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
                    result.success(address?.hostAddress ?: error("No local IPv4 address is available"))
                }
                "load" -> {
                    val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MUSIC_TRACK)
                    metadata.putString(MediaMetadata.KEY_TITLE, call.argument<String>("title") ?: "")
                    metadata.putString(MediaMetadata.KEY_ARTIST, call.argument<String>("artist") ?: "")
                    metadata.putString(MediaMetadata.KEY_ALBUM_TITLE, call.argument<String>("album") ?: "")
                    call.argument<String>("artwork")?.takeIf { it.isNotEmpty() }?.let { metadata.addImage(WebImage(Uri.parse(it))) }
                    val data = JSONObject(call.argument<String>("customData") ?: "{}")
                    val info = MediaInfo.Builder(call.argument<String>("url")!!)
                        .setContentType(call.argument<String>("mime")!!)
                        .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED).setMetadata(metadata)
                        .setCustomData(data).setStreamDuration(call.argument<Number>("durationMs")?.toLong() ?: 0L).build()
                    val request = MediaLoadRequestData.Builder().setMediaInfo(info)
                        .setAutoplay(call.argument<Boolean>("autoplay") ?: true)
                        .setCurrentTime(call.argument<Number>("positionMs")?.toLong() ?: 0L).build()
                    val remote = client ?: error("No TV is connected")
                    remote.load(request).setResultCallback {
                        if (it.status.isSuccess) result.success(null)
                        else result.error("cast_load", "TV rejected the track (${it.status.statusCode})", null)
                    }
                }
                "play", "pause", "seek", "stop" -> {
                    val remote = client ?: error("No TV is connected")
                    val pending = when (call.method) {
                        "play" -> remote.play()
                        "pause" -> remote.pause()
                        "seek" -> remote.seek(MediaSeekOptions.Builder().setPosition(call.argument<Number>("positionMs")!!.toLong()).build())
                        else -> remote.stop()
                    }
                    pending.setResultCallback {
                        if (it.status.isSuccess) result.success(null)
                        else result.error("cast_command", "TV command failed (${it.status.statusCode})", null)
                    }
                }
                "volume" -> {
                    val remote = client ?: error("No TV is connected")
                    remote.setStreamVolume((call.argument<Number>("volume")!!.toDouble()).coerceIn(0.0, 1.0)).setResultCallback {
                        if (it.status.isSuccess) result.success(null) else result.error("cast_volume", "Could not update TV volume", null)
                    }
                }
                "message" -> {
                    val session = cast!!.sessionManager.currentCastSession ?: error("No TV is connected")
                    session.sendMessage(namespace, call.argument<String>("data")!!).setResultCallback {
                        if (it.isSuccess) result.success(null) else result.error("cast_message", "Could not update TV (${it.statusCode})", null)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { result.error("cast_unavailable", e.message, null) }
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null; activity = null
        pendingDiscovery?.error("cast_permission", "Open Cast again to allow local network access", null)
        pendingDiscovery = null
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != 7124) return false
        val result = pendingDiscovery ?: return true
        pendingDiscovery = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            onMethodCall(io.flutter.plugin.common.MethodCall("discover", null), result)
        } else result.error("cast_permission", "Allow local network access to discover and connect to your TV", null)
        return true
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        router?.removeCallback(routeCallback)
        cast?.sessionManager?.removeSessionManagerListener(listener, CastSession::class.java)
        client?.removeProgressListener(progressListener)
        client?.unregisterCallback(mediaCallback)
        methods.setMethodCallHandler(null); events.setStreamHandler(null); sink = null
    }
}
