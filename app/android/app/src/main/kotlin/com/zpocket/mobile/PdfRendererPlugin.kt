package com.zpocket.mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt
import kotlin.math.sqrt

/// PDF 产物预览原生通道（companion/pdf）：基于 Android 内置 [PdfRenderer]
/// 逐页渲染 PNG 字节回传 Dart，零第三方原生依赖。
///
/// 线程纪律：Android [PdfRenderer] 非线程安全且单次只能打开一页——所有打开、
/// 渲染、关闭统一串行调度到单线程 [executor]，结果经 [mainHandler] 回主线程。
object PdfRendererPlugin {
    private const val CHANNEL = "companion/pdf"
    private const val DEFAULT_MAX_WIDTH = 1440
    private const val MIN_WIDTH = 200
    private const val MAX_LONG_SIDE = 4096
    private const val MAX_PIXELS = 4_194_304L

    private class OpenDoc(
        val generation: Long,
        val pfd: ParcelFileDescriptor,
        val renderer: PdfRenderer,
    ) {
        fun closeQuietly() {
            try {
                renderer.close()
            } catch (_: Exception) {
            }
            try {
                pfd.close()
            } catch (_: Exception) {
            }
        }
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val bindGeneration = AtomicLong(0L)
    private val docs = ConcurrentHashMap<String, OpenDoc>()
    private val closedHandles = ConcurrentHashMap.newKeySet<String>()
    private val closedGenerations = ConcurrentHashMap.newKeySet<Long>()

    fun bind(flutterEngine: FlutterEngine, context: Context): Long {
        val generation = bindGeneration.incrementAndGet()
        val appContext = context.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val path = call.argument<String>("path")
                        handleOpen(appContext, path, generation, result)
                    }
                    "renderPage" -> {
                        val handle = call.argument<String>("handle")
                        val pageIndex = call.argument<Int>("pageIndex")
                        val maxWidth = call.argument<Int>("maxWidth")
                        handleRenderPage(handle, pageIndex, maxWidth, result)
                    }
                    "close" -> {
                        val handle = call.argument<String>("handle")
                        handleClose(handle, result)
                    }
                    else -> result.notImplemented()
                }
            }
        return generation
    }

    private fun handleOpen(
        appContext: Context,
        path: String?,
        generation: Long,
        result: MethodChannel.Result,
    ) {
        if (path.isNullOrBlank()) {
            result.error("invalid", "Missing PDF path", null)
            return
        }
        val file = File(path)
        val isValidCacheFile = try {
            val cacheRoot = appContext.cacheDir.canonicalPath
            val prefix = if (cacheRoot.endsWith(File.separator)) {
                cacheRoot
            } else {
                "$cacheRoot${File.separator}"
            }
            val canonical = file.canonicalPath
            file.isFile && canonical.startsWith(prefix)
        } catch (_: Exception) {
            false
        }
        if (!isValidCacheFile) {
            result.error("invalid", "PDF path outside cache directory", null)
            return
        }

        if (closedGenerations.contains(generation)) {
            result.error("invalid", "Engine closed", null)
            return
        }

        executor.execute {
            if (closedGenerations.contains(generation)) {
                mainHandler.post {
                    result.error("invalid", "Engine closed", null)
                }
                return@execute
            }
            var pfd: ParcelFileDescriptor? = null
            var renderer: PdfRenderer? = null
            try {
                pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                renderer = PdfRenderer(pfd)
                val pageCount = renderer.pageCount
                if (pageCount <= 0) {
                    try {
                        renderer.close()
                    } catch (_: Throwable) {
                    }
                    try {
                        pfd.close()
                    } catch (_: Throwable) {
                    }
                    mainHandler.post {
                        result.error("invalid", "PDF has no pages", null)
                    }
                    return@execute
                }
                if (closedGenerations.contains(generation)) {
                    try {
                        renderer.close()
                    } catch (_: Throwable) {
                    }
                    try {
                        pfd.close()
                    } catch (_: Throwable) {
                    }
                    mainHandler.post {
                        result.error("invalid", "Engine closed", null)
                    }
                    return@execute
                }
                val handle = UUID.randomUUID().toString()
                docs[handle] = OpenDoc(generation, pfd, renderer)
                mainHandler.post {
                    result.success(
                        mapOf(
                            "handle" to handle,
                            "pageCount" to pageCount,
                        ),
                    )
                }
            } catch (_: SecurityException) {
                try {
                    renderer?.close()
                } catch (_: Throwable) {
                }
                try {
                    pfd?.close()
                } catch (_: Throwable) {
                }
                mainHandler.post {
                    result.error("encrypted", "PDF is password protected", null)
                }
            } catch (t: Throwable) {
                try {
                    renderer?.close()
                } catch (_: Throwable) {
                }
                try {
                    pfd?.close()
                } catch (_: Throwable) {
                }
                mainHandler.post {
                    result.error("invalid", t.message ?: "open failed", null)
                }
            }
        }
    }

    private fun handleRenderPage(
        handle: String?,
        pageIndex: Int?,
        rawMaxWidth: Int?,
        result: MethodChannel.Result,
    ) {
        if (handle.isNullOrBlank() || pageIndex == null) {
            result.error("render_failed", "Missing render arguments", null)
            return
        }
        if (closedHandles.contains(handle)) {
            result.error("render_failed", "PDF document is closed", null)
            return
        }
        val maxWidth = (rawMaxWidth ?: DEFAULT_MAX_WIDTH).coerceIn(MIN_WIDTH, MAX_LONG_SIDE)

        executor.execute {
            if (closedHandles.contains(handle)) {
                mainHandler.post {
                    result.error("render_failed", "PDF document is closed", null)
                }
                return@execute
            }
            try {
                val doc = docs[handle]
                    ?: throw IllegalStateException("PDF document is not open")
                if (pageIndex !in 0 until doc.renderer.pageCount) {
                    throw IndexOutOfBoundsException("Page index out of range: $pageIndex")
                }
                val pngBytes = doc.renderer.openPage(pageIndex).use { page ->
                    val pageW = page.width.coerceAtLeast(1)
                    val pageH = page.height.coerceAtLeast(1)
                    var w = maxWidth.toDouble()
                    var h = pageH.toDouble() * (w / pageW.toDouble())
                    val maxDim = maxOf(w, h)
                    val pixels = w * h
                    if (maxDim > MAX_LONG_SIDE || pixels > MAX_PIXELS) {
                        val shrink = minOf(
                            MAX_LONG_SIDE.toDouble() / maxDim,
                            sqrt(MAX_PIXELS.toDouble() / pixels),
                        )
                        w *= shrink
                        h *= shrink
                    }
                    val targetW = w.roundToInt().coerceIn(1, MAX_LONG_SIDE)
                    val targetH = h.roundToInt().coerceIn(1, MAX_LONG_SIDE)

                    var bmp: Bitmap? = null
                    try {
                        bmp = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                        // 透明底 PDF 先铺白纸，避免深色主题下黑字不可见。
                        Canvas(bmp).drawColor(Color.WHITE)
                        page.render(
                            bmp,
                            null,
                            null,
                            PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY,
                        )
                        val out = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                        out.toByteArray()
                    } finally {
                        bmp?.recycle()
                    }
                }
                mainHandler.post {
                    result.success(pngBytes)
                }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("render_failed", t.message ?: "render failed", null)
                }
            }
        }
    }

    private fun handleClose(handle: String?, result: MethodChannel.Result) {
        if (handle.isNullOrBlank()) {
            result.success(true)
            return
        }
        closedHandles.add(handle)
        executor.execute {
            docs.remove(handle)?.closeQuietly()
            closedHandles.remove(handle)
            mainHandler.post {
                result.success(true)
            }
        }
    }

    /// 按引擎代次隔离释放：只关闭属于该旧 Activity/引擎代次的文档，绝不误关新引擎文档。
    fun closeForGeneration(generation: Long) {
        if (generation <= 0L) return
        closedGenerations.add(generation)
        val targets = docs.entries
            .filter { it.value.generation == generation }
            .map { it.key }
        if (targets.isNotEmpty()) {
            closedHandles.addAll(targets)
        }
        executor.execute {
            val toClose = docs.entries
                .filter { it.value.generation == generation }
                .map { it.key }
            for (key in toClose) {
                docs.remove(key)?.closeQuietly()
                closedHandles.remove(key)
            }
            if (targets.isNotEmpty()) {
                closedHandles.removeAll(targets.toSet())
            }
        }
    }
}
