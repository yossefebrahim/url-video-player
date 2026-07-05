package info.t4w.vp

import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Hosts the Flutter UI and bridges native Android capabilities to Dart:
 *
 *  - getInitialLink (MethodChannel) delivers the intent that cold-started the app.
 *  - the EventChannel streams intents that arrive while the app is already
 *    running (onNewIntent, thanks to launchMode="singleTop").
 *  - generateThumbnail (MethodChannel) extracts a poster frame from a video URL
 *    via MediaMetadataRetriever (supports custom User-Agent headers).
 */
class MainActivity : FlutterActivity() {
    private val methodChannelName = "info.t4w.vp/deeplink"
    private val eventChannelName = "info.t4w.vp/deeplink/events"

    private var initialLink: HashMap<String, String?>? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Capture the intent that launched this activity (may be null / launcher).
        initialLink = intentToMap(intent)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        result.success(initialLink)
                        // Deliver the cold-start link only once so hot restarts
                        // don't replay it.
                        initialLink = null
                    }
                    "generateThumbnail" -> {
                        val url = call.argument<String>("url")
                        val userAgent = call.argument<String>("userAgent")
                        val outPath = call.argument<String>("outPath")
                        if (url == null || outPath == null) {
                            result.success(null)
                        } else {
                            generateThumbnail(url, userAgent, outPath, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intentToMap(intent)?.let { eventSink?.success(it) }
    }

    /** Extracts a video-link payload from a supported intent, or null. */
    private fun intentToMap(intent: Intent?): HashMap<String, String?>? {
        if (intent == null) return null

        // Explicit-component hand-off (Ostora-style): the URL arrives as an
        // "url" extra (optionally with an "agent" user-agent), not as VIEW data.
        val extraUrl = intent.getStringExtra("url")
        if (!extraUrl.isNullOrEmpty()) {
            return hashMapOf(
                "type" to "extra",
                "url" to extraUrl,
                "agent" to intent.getStringExtra("agent"),
            )
        }

        return when (intent.action) {
            Intent.ACTION_VIEW, Intent.ACTION_EDIT, Intent.ACTION_PICK,
            Intent.ACTION_GET_CONTENT -> {
                val data = intent.dataString ?: return null
                hashMapOf("type" to "view", "uri" to data)
            }
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
                hashMapOf("type" to "send", "text" to text)
            }
            else -> null
        }
    }

    /**
     * Grabs a representative frame off the main thread and writes it as a JPEG
     * to [outPath]. Replies with the path on success or null on any failure
     * (e.g. HLS sources the retriever can't decode).
     */
    private fun generateThumbnail(
        url: String,
        userAgent: String?,
        outPath: String,
        result: MethodChannel.Result,
    ) {
        Thread {
            var path: String? = null
            val retriever = MediaMetadataRetriever()
            try {
                val headers = HashMap<String, String>()
                if (!userAgent.isNullOrEmpty()) headers["User-Agent"] = userAgent
                if (url.startsWith("http")) {
                    retriever.setDataSource(url, headers)
                } else {
                    // content:// and file:// must go through the Context+Uri
                    // overload; the single-arg String form can't resolve them.
                    retriever.setDataSource(applicationContext, Uri.parse(url))
                }
                val frame: Bitmap? = retriever.getFrameAtTime(
                    1_000_000, // 1s in, to skip black intros
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
                if (frame != null) {
                    val out = File(outPath)
                    out.parentFile?.mkdirs()
                    FileOutputStream(out).use { fos ->
                        frame.compress(Bitmap.CompressFormat.JPEG, 80, fos)
                    }
                    frame.recycle()
                    if (out.exists() && out.length() > 0) path = outPath
                }
            } catch (e: Exception) {
                Log.w("UrlVideoPlayer", "thumbnail generation failed for $url", e)
            } finally {
                try {
                    retriever.release()
                } catch (_: Exception) {
                }
            }
            mainHandler.post { result.success(path) }
        }.start()
    }
}
