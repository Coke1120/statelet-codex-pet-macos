from __future__ import annotations

import importlib
import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import warnings
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from fractions import Fraction
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
alpha = importlib.import_module("tools.codex_pet_alpha")
converter = importlib.import_module("tools.convert_codex_pet_macos_alpha")


class MacOSAlphaCommandTests(unittest.TestCase):
    def test_progress_jsonl_is_parseable_flushed_monotonic_and_path_free(self):
        class FlushTrackingStream(io.StringIO):
            def __init__(self):
                super().__init__()
                self.flush_count = 0

            def flush(self):
                self.flush_count += 1
                super().flush()

        stream = FlushTrackingStream()
        progress = converter._ProgressReporter(True, stream=stream)
        progress.emit(0, stage="probe", message="Probing source video")
        progress.emit(
            42,
            stage="matte",
            message="Matting source frames",
            frame_completed=2,
            frame_total=5,
        )
        progress.emit(31, stage="encode", message="Encoding HEVC with alpha")
        progress.emit(
            100,
            stage="complete",
            message="Conversion complete",
            status="completed",
        )

        lines = stream.getvalue().splitlines()
        events = [json.loads(line) for line in lines]
        self.assertEqual(stream.flush_count, len(events))
        self.assertEqual([event["percent"] for event in events], [0, 42, 42, 100])
        self.assertTrue(all(event["event"] == "progress" for event in events))
        self.assertTrue(all("stage" in event and "message" in event for event in events))
        self.assertEqual(events[1]["completed_frames"], 2)
        self.assertEqual(events[1]["total_frames"], 5)
        self.assertEqual(events[-1]["status"], "completed")
        rendered = "\n".join(lines)
        self.assertNotIn("/Users/", rendered)
        self.assertNotIn(str(ROOT), rendered)

    def test_progress_jsonl_failure_is_safe_and_does_not_emit_pretty_report(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(
            converter,
            "convert_video",
            side_effect=converter.AlphaConversionError(
                "/Users/example/private/source.mp4 failed"
            ),
        ), redirect_stdout(stdout), redirect_stderr(stderr):
            result = converter.main(
                ["source.mp4", "pet.mov", "--progress-jsonl"]
            )

        self.assertEqual(result, 2)
        events = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["status"], "failed")
        self.assertEqual(events[0]["stage"], "failed")
        self.assertNotIn("/Users/example", stdout.getvalue())
        self.assertNotIn("/Users/example", stderr.getvalue())
        self.assertIn("error: <local-file>", stderr.getvalue())

    def test_default_main_output_remains_one_final_json_document(self):
        report = {"status": "converted", "source": {"name": "source.mp4"}}
        stdout = io.StringIO()
        with mock.patch.object(converter, "convert_video", return_value=report), redirect_stdout(
            stdout
        ):
            result = converter.main(["source.mp4", "pet.mov"])

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout.getvalue()), report)
        self.assertNotIn('"event": "progress"', stdout.getvalue())

    def test_progress_main_emits_jsonl_through_full_completion(self):
        def fake_convert(_args, *, progress):
            progress.emit(0, stage="probe", message="Probing source video")
            progress.emit(
                50,
                stage="matte",
                message="Matting source frames",
                frame_completed=3,
                frame_total=6,
            )
            progress.emit(70, stage="encode", message="HEVC-alpha encode complete")
            progress.emit(98, stage="publish", message="Publishing verified artifacts")
            progress.emit(
                100,
                stage="complete",
                message="Conversion complete",
                status="completed",
            )
            return {"status": "converted"}

        stdout = io.StringIO()
        with mock.patch.object(converter, "convert_video", side_effect=fake_convert), redirect_stdout(
            stdout
        ):
            result = converter.main(
                ["source.mp4", "pet.mov", "--progress-jsonl"]
            )

        self.assertEqual(result, 0)
        events = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(events[-1]["percent"], 100)
        self.assertEqual(events[-1]["status"], "completed")
        self.assertEqual(
            {event["stage"] for event in events},
            {"probe", "matte", "encode", "publish", "complete"},
        )
        self.assertEqual(events[1]["completed_frames"], 3)
        self.assertEqual(events[1]["total_frames"], 6)

    def test_ffprobe_command_counts_frames_and_attached_art_is_distinguished(self):
        command = alpha.build_ffprobe_command("input.mp4", ffprobe="custom-ffprobe")
        self.assertEqual(command[0], "custom-ffprobe")
        self.assertIn("-count_frames", command)
        entries = command[command.index("-show_entries") + 1]
        self.assertIn("avg_frame_rate", entries)
        self.assertIn("r_frame_rate", entries)
        self.assertIn("nb_read_frames", entries)
        self.assertIn("sample_aspect_ratio", entries)
        self.assertIn("stream_disposition=attached_pic", entries)

    def test_ffmpeg_and_avconvert_commands_use_alpha_contract(self):
        decode = alpha.build_ffmpeg_decode_command(
            "/private/source.mp4", width=640, height=360, ffmpeg="ffmpeg-custom"
        )
        self.assertEqual(decode[0], "ffmpeg-custom")
        self.assertIn("-map", decode)
        self.assertEqual(decode[decode.index("-pix_fmt") + 1], "rgb24")
        self.assertEqual(decode[decode.index("-vsync") + 1], "0")
        self.assertNotIn("-r", decode)
        self.assertEqual(
            decode[decode.index("-vf") + 1],
            "scale=640:360:force_original_aspect_ratio=increase:flags=lanczos,"
            "crop=640:360:(iw-ow)*0.5:(ih-oh)*0.5,setsar=1",
        )
        self.assertNotIn("scale=640:360:flags=lanczos", decode)
        roundtrip_decode = alpha.build_ffmpeg_rgba_decode_command(
            "/tmp/roundtrip.mov", width=640, height=360
        )
        self.assertEqual(roundtrip_decode[roundtrip_decode.index("-pix_fmt") + 1], "rgba")
        self.assertNotIn("alphaextract", roundtrip_decode)
        self.assertEqual(
            roundtrip_decode[roundtrip_decode.index("-vf") + 1],
            "scale=640:360:flags=lanczos",
        )
        prores = alpha.build_ffmpeg_prores_command(
            "/tmp/intermediate.mov",
            width=640,
            height=360,
            fps="24/1",
        )
        self.assertIn("rgba", prores)
        self.assertIn("prores_ks", prores)
        self.assertEqual(prores[prores.index("-profile:v") + 1], "4")
        self.assertEqual(prores[-2], "yuva444p10le")
        av = alpha.build_avconvert_command(
            "/tmp/intermediate.mov",
            "/tmp/output.mov",
            avconvert="avconvert-custom",
        )
        self.assertEqual(av[0], "avconvert-custom")
        self.assertIn("PresetHEVCHighestQualityWithAlpha", av)
        self.assertIn("--replace", av)

    def test_source_decode_aspect_fills_landscape_into_portrait_canvas(self):
        command = alpha.build_ffmpeg_decode_command(
            "landscape.mp4", width=320, height=480
        )

        video_filter = command[command.index("-vf") + 1]
        self.assertEqual(
            video_filter,
            "scale=320:480:force_original_aspect_ratio=increase:flags=lanczos,"
            "crop=320:480:(iw-ow)*0.5:(ih-oh)*0.5,setsar=1",
        )
        self.assertNotEqual(video_filter, "scale=320:480:flags=lanczos")

    def test_source_decode_matching_ratio_remains_geometry_exact(self):
        command = alpha.build_ffmpeg_decode_command(
            "matching-ratio.mp4", width=320, height=480
        )

        video_filter = command[command.index("-vf") + 1]
        self.assertIn("force_original_aspect_ratio=increase", video_filter)
        self.assertIn("crop=320:480:(iw-ow)*0.5:(ih-oh)*0.5", video_filter)
        self.assertTrue(video_filter.endswith("setsar=1"))
        self.assertEqual(command[command.index("-pix_fmt") + 1], "rgb24")

    @unittest.skipUnless(
        alpha.np is not None and alpha.Image is not None and shutil.which("ffmpeg"),
        "NumPy, Pillow, and ffmpeg are required",
    )
    def test_aspect_fill_preserves_square_proportions_for_landscape_and_matching_ratio(self):
        np = alpha.np
        image_type = alpha.Image
        ffmpeg = shutil.which("ffmpeg")
        assert np is not None and image_type is not None and ffmpeg is not None

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for label, source_width, source_height, square_size in (
                ("landscape", 1280, 720, 180),
                ("matching", 320, 480, 120),
            ):
                with self.subTest(label=label):
                    frame = np.zeros((source_height, source_width, 3), dtype=np.uint8)
                    frame[:, :] = (0, 255, 0)
                    left = (source_width - square_size) // 2
                    top = (source_height - square_size) // 2
                    frame[top : top + square_size, left : left + square_size] = (
                        255,
                        255,
                        255,
                    )
                    source = root / f"{label}.png"
                    image_type.fromarray(frame, mode="RGB").save(source)

                    result = subprocess.run(
                        alpha.build_ffmpeg_decode_command(
                            source,
                            width=320,
                            height=480,
                            ffmpeg=ffmpeg,
                        ),
                        check=True,
                        stdout=subprocess.PIPE,
                    )
                    self.assertEqual(len(result.stdout), 320 * 480 * 3)
                    output = np.frombuffer(result.stdout, dtype=np.uint8).reshape(
                        (480, 320, 3)
                    )
                    white = np.all(output > 240, axis=2)
                    rows, columns = np.nonzero(white)
                    rendered_width = int(columns.max() - columns.min() + 1)
                    rendered_height = int(rows.max() - rows.min() + 1)
                    self.assertLessEqual(
                        abs(rendered_width - rendered_height),
                        2,
                        "aspect-fill must not squeeze a square foreground",
                    )
                    self.assertGreater(rendered_width, 100)

    def test_dry_run_report_records_aspect_fill_resize_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            output = root / "waiting.mov"
            report_path = root / "waiting.report.json"
            source.write_bytes(b"source")
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(output),
                    "--report",
                    str(report_path),
                    "--width",
                    "320",
                    "--height",
                    "480",
                    "--dry-run",
                ]
            )
            info = alpha.VideoInfo(
                width=1280,
                height=720,
                frame_count=240,
                fps=Fraction(24, 1),
                duration_seconds=10.0,
                codec_name="h264",
                pixel_format="yuv420p",
                codec_profile="High",
            )
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "require_tool", side_effect=lambda _name, requested: requested
            ), mock.patch.object(converter, "probe_video", return_value=info):
                report = converter.convert_video(args)

            self.assertEqual(
                report["source_framing"]["resize_mode"],
                alpha.SOURCE_RESIZE_MODE,
            )
            self.assertEqual(report["geometry"], {"width": 320, "height": 480})
            self.assertIn(
                "force_original_aspect_ratio=increase",
                report["commands"]["decode"][
                    report["commands"]["decode"].index("-vf") + 1
                ],
            )
            self.assertEqual(
                json.loads(report_path.read_text(encoding="utf-8"))["source_framing"][
                    "resize_mode"
                ],
                alpha.SOURCE_RESIZE_MODE,
            )

    def test_dry_run_report_declares_source_audio_is_stripped(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source-with-audio.mp4"
            output = root / "review.mov"
            report_path = root / "review.report.json"
            source.write_bytes(b"source")
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(output),
                    "--report",
                    str(report_path),
                    "--width",
                    "320",
                    "--height",
                    "480",
                    "--dry-run",
                ]
            )
            info = alpha.VideoInfo(
                width=720,
                height=1280,
                frame_count=240,
                fps=Fraction(24, 1),
                duration_seconds=10.0,
                codec_name="h264",
                pixel_format="yuv420p",
                codec_profile="High",
                audio_codecs=("aac",),
            )
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "require_tool", side_effect=lambda _name, requested: requested
            ), mock.patch.object(converter, "probe_video", return_value=info):
                report = converter.convert_video(args)

            self.assertEqual(
                report["source"]["audio"],
                {
                    "stream_count": 1,
                    "codecs": ["aac"],
                    "policy": "stripped",
                },
            )
            self.assertIn("-an", report["commands"]["decode"])

    @unittest.skipUnless(alpha.np is not None, "NumPy is required")
    def test_loop_seam_diagnostics_are_informational(self):
        np = alpha.np
        assert np is not None
        first = np.zeros((2, 3, 4), dtype=np.uint8)
        last = first.copy()
        last[1, 2, 0] = 12

        diagnostics = converter._loop_seam_diagnostics(first, last)

        self.assertEqual(
            diagnostics,
            {
                "performed": True,
                "exact_match": False,
                "differing_pixels": 1,
                "mean_absolute_error": 0.5,
                "maximum_absolute_error": 12,
                "policy": "informational",
            },
        )

    def test_odd_requested_geometry_is_aligned_before_encoding(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            output = root / "review.mov"
            report_path = root / "review.report.json"
            source.write_bytes(b"source")
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(output),
                    "--report",
                    str(report_path),
                    "--width",
                    "341",
                    "--height",
                    "511",
                    "--dry-run",
                ]
            )
            info = alpha.VideoInfo(
                width=720,
                height=1280,
                frame_count=240,
                fps=Fraction(24, 1),
                duration_seconds=10.0,
                codec_name="h264",
                pixel_format="yuv420p",
                codec_profile="High",
            )
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "require_tool", side_effect=lambda _name, requested: requested
            ), mock.patch.object(converter, "probe_video", return_value=info):
                report = converter.convert_video(args)

            self.assertEqual(report["geometry"], {"width": 340, "height": 510})
            self.assertEqual(
                report["geometry_alignment"],
                {
                    "requested_width": 341,
                    "requested_height": 511,
                    "policy": "floor_to_even",
                    "adjusted": True,
                },
            )
            decode = report["commands"]["decode"]
            self.assertIn("scale=340:510", decode[decode.index("-vf") + 1])
            persisted = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(persisted["geometry"], {"width": 340, "height": 510})

    def test_hevc_geometry_alignment_rejects_subpixel_canvas(self):
        with self.assertRaisesRegex(
            alpha.AlphaConversionError,
            "at least 4 pixels",
        ):
            converter._align_hevc_alpha_geometry(3, 511)

    def test_hevc_geometry_alignment_handles_each_axis_independently(self):
        for requested, expected in (
            ((340, 510), (340, 510)),
            ((341, 510), (340, 510)),
            ((340, 511), (340, 510)),
            ((341, 511), (340, 510)),
        ):
            with self.subTest(requested=requested):
                self.assertEqual(
                    converter._align_hevc_alpha_geometry(*requested),
                    expected,
                )

    def test_geometry_mismatch_reports_actual_and_expected_dimensions(self):
        actual = alpha.VideoInfo(
            width=340,
            height=510,
            frame_count=240,
            fps=Fraction(24, 1),
            duration_seconds=10.0,
            codec_name="hevc",
            pixel_format="yuv420p",
        )
        expected = alpha.VideoInfo(
            width=341,
            height=511,
            frame_count=240,
            fps=Fraction(24, 1),
            duration_seconds=10.0,
            codec_name="",
            pixel_format="",
        )
        with self.assertRaisesRegex(
            alpha.FrameQualityError,
            "HEVC delivery geometry is 340x510; expected 341x511",
        ):
            converter._verify_basic_info(
                actual,
                expected,
                expected_codec="hevc",
                label="HEVC delivery",
            )

    def test_rgba_decoder_pair_closes_reference_when_delivery_spawn_fails(self):
        first_decoder = mock.Mock()
        with mock.patch.object(
            converter,
            "_start_process",
            side_effect=[first_decoder, OSError("second decoder spawn failed")],
        ), mock.patch.object(converter, "close_process") as close_process:
            with self.assertRaises(OSError):
                converter._start_rgba_decoder_pair(
                    Path("reference.mov"),
                    Path("roundtrip.mov"),
                    width=4,
                    height=4,
                    ffmpeg="ffmpeg",
                )
        close_process.assert_called_once_with(first_decoder)

    def test_stream_matte_failure_reports_the_one_based_source_frame(self):
        decoder = mock.Mock()
        encoder = mock.Mock()
        encoder.stdin = mock.Mock()
        info = alpha.VideoInfo(
            width=4,
            height=4,
            frame_count=1,
            fps=Fraction(24, 1),
            duration_seconds=1 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(
            converter, "_start_process", side_effect=[decoder, encoder]
        ), mock.patch.object(
            converter, "read_raw_frames", return_value=iter([object()])
        ), mock.patch.object(
            converter,
            "matte_frame",
            side_effect=alpha.FrameQualityError(
                "magenta edge ratio/channel excess exceeds configured limit"
            ),
        ), mock.patch.object(converter, "close_process"):
            with self.assertRaisesRegex(
                alpha.FrameQualityError,
                "source frame 1: magenta edge ratio/channel excess",
            ):
                converter._stream_matte_to_prores(
                    Path("source.mp4"),
                    Path(temp) / "intermediate.mov",
                    Path(temp) / "alpha.raw",
                    info=info,
                    width=4,
                    height=4,
                    ffmpeg="ffmpeg",
                    border_width=1,
                    key_floor=0.06,
                    key_ceiling=0.94,
                    despill_strength=0.8,
                    despill_allowance=2.0,
                    max_green_edge_ratio=0.15,
                    max_magenta_edge_ratio=0.15,
                    source_edge_alpha_floor=64,
                    max_green_edge_excess=96,
                    max_magenta_edge_excess=96,
                    allow_empty_frame=False,
                    reject_edge_contact=False,
                )

    def test_parser_exposes_practical_matting_and_tool_flags(self):
        args = converter.build_parser().parse_args(
            [
                "source.mp4",
                "pet.mov",
                "--ffprobe",
                "probe",
                "--ffmpeg",
                "mpeg",
                "--avconvert",
                "convert",
                "--border-width",
                "3",
                "--key-floor",
                "0.08",
                "--key-ceiling",
                "0.9",
                "--despill-strength",
                "0.7",
                "--strict-source-framing",
                "--replace",
            ]
        )
        self.assertEqual(args.border_width, 3)
        self.assertEqual(args.key_floor, 0.08)
        self.assertEqual(args.key_ceiling, 0.9)
        self.assertEqual(args.despill_strength, 0.7)
        self.assertTrue(args.strict_source_framing)
        self.assertTrue(args.replace)
        relaxed = converter.build_parser().parse_args(["source.mp4", "pet.mov"])
        self.assertFalse(relaxed.strict_source_framing)
        self.assertEqual(relaxed.max_border_alpha, 16)
        explicit_border = converter.build_parser().parse_args(
            ["source.mp4", "pet.mov", "--max-border-alpha", "12"]
        )
        self.assertEqual(explicit_border.max_border_alpha, 12)
        self.assertEqual(
            relaxed.max_green_edge_ratio, alpha.DEFAULT_MAX_SOURCE_EDGE_RATIO
        )
        self.assertEqual(
            relaxed.max_magenta_edge_ratio, alpha.DEFAULT_MAX_SOURCE_EDGE_RATIO
        )
        self.assertEqual(
            relaxed.max_green_edge_excess,
            alpha.DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS,
        )
        self.assertEqual(
            relaxed.max_magenta_edge_excess,
            alpha.DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS,
        )
        with mock.patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit):
                converter.build_parser().parse_args(
                    ["source.mp4", "pet.mov", "--skip-verification"]
                )

    def test_report_safe_name_never_contains_private_parent(self):
        private = Path("/Users/example/private-assets/character/source.mp4")
        self.assertEqual(converter._safe_name(private), "source.mp4")

    def test_sanitize_command_removes_private_paths_but_keeps_frame_rate(self):
        command = alpha.sanitize_command(
            [
                "/Users/example/bin/ffmpeg",
                "-r",
                "24/1",
                "/Users/example/private/source.mp4",
            ]
        )
        self.assertEqual(command, ["ffmpeg", "-r", "24/1", "source.mp4"])

    def test_report_sanitizer_preserves_quality_slashes_and_redacts_embedded_paths(self):
        message = "magenta edge ratio/channel excess exceeds configured limit (69 > 64)"
        self.assertEqual(converter._safe_report_value(message), message)

        embedded = "source=/Users/example/private/source.mp4 failed at Frame 3/24"
        sanitized = converter._safe_report_value(embedded)
        self.assertNotIn("/Users/example", sanitized)
        self.assertEqual(sanitized, "source=<local-file>")

        quoted = 'open "/Users/alice/My Videos/source clip.mp4" failed'
        self.assertEqual(
            converter._safe_report_value(quoted),
            'open "<local-file>" failed',
        )
        volume = "copy /Volumes/Client Work/secret/source.mov"
        self.assertEqual(
            converter._safe_report_value(volume),
            "copy <local-file>",
        )
        url = "https://example.com/Users/demo/video.mp4"
        self.assertEqual(converter._safe_report_value(url), url)

        command = alpha.sanitize_command(
            ["/Users/example/My Videos/source clip.mp4"]
        )
        self.assertEqual(command, ["source clip.mp4"])

    def test_frame_quality_enforces_configured_roundtrip_border_limit(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((8, 8, 4), dtype=np.uint8)
        rgba[3:5, 3:5, 3] = 255
        rgba[0, 2, 3] = 7
        self.assertEqual(
            alpha.frame_quality(rgba, max_outer_edge_alpha=8)[
                "outer_edge_alpha_maximum"
            ],
            7,
        )
        with self.assertRaisesRegex(alpha.FrameQualityError, "outer-edge alpha"):
            alpha.frame_quality(rgba, max_outer_edge_alpha=6)

        rgba[0, 2, 3] = 16
        self.assertEqual(alpha.DEFAULT_MAX_BORDER_ALPHA, 16)
        self.assertEqual(
            alpha.frame_quality(
                rgba,
                max_outer_edge_alpha=alpha.DEFAULT_MAX_BORDER_ALPHA,
            )["outer_edge_alpha_maximum"],
            16,
        )
        rgba[0, 2, 3] = 17
        with self.assertRaisesRegex(alpha.FrameQualityError, "outer-edge alpha"):
            alpha.frame_quality(
                rgba,
                max_outer_edge_alpha=alpha.DEFAULT_MAX_BORDER_ALPHA,
            )

    def test_frame_quality_still_rejects_unrepaired_magenta_fringe(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((8, 8, 4), dtype=np.uint8)
        rgba[2:6, 2:6, :3] = (120, 128, 136)
        rgba[2:6, 2:6, 3] = 255
        rgba[1:7, 1:7, :3][rgba[1:7, 1:7, 3] == 0] = (255, 0, 255)
        rgba[1:7, 1:7, 3][rgba[1:7, 1:7, 3] == 0] = 64
        with self.assertRaisesRegex(alpha.FrameQualityError, "magenta edge ratio"):
            alpha.frame_quality(rgba)

    def test_composite_quality_rejects_translucent_green_contamination(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((12, 12, 4), dtype=np.uint8)
        rgba[4:8, 4:8, :3] = (190, 170, 150)
        rgba[4:8, 4:8, 3] = 255
        # The green ring is translucent, so a source-RGB-only gate can miss
        # it.  All three neutral composites must classify and reject it.
        rgba[3:9, 3:9, :3] = (24, 220, 24)
        rgba[3:9, 3:9, 3] = 96
        rgba[4:8, 4:8, :3] = (190, 170, 150)
        rgba[4:8, 4:8, 3] = 255
        with self.assertRaisesRegex(alpha.FrameQualityError, "green fringe ratio"):
            alpha.composite_quality(rgba)

    def test_composite_quality_accepts_authorized_matte_without_false_positive(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        frame, _ = MacOSAlphaSyntheticMatteTests()._synthetic_frame()
        rgba = alpha.matte_frame(frame)
        metrics = alpha.composite_quality(rgba)
        self.assertEqual(
            metrics["background_names"], ["white", "black", "checkerboard"]
        )
        self.assertTrue(metrics["quality_passed"])
        self.assertLessEqual(
            metrics["maximum_delivery_green_fringe_ratio"],
            alpha.DEFAULT_MAX_GREEN_FRINGE_RATIO,
        )
        self.assertLessEqual(
            metrics["maximum_delivery_magenta_fringe_ratio"],
            alpha.DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
        )

    def test_composite_quality_rejects_four_severe_pixels_even_when_ratio_is_diluted(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        reference = np.zeros((64, 64, 4), dtype=np.uint8)
        reference[1:-1, 1:-1, :3] = (120, 128, 136)
        reference[1:-1, 1:-1, 3] = 128
        delivery = reference.copy()
        delivery[20:22, 20:22, :3] = (0, 255, 0)
        with self.assertRaisesRegex(alpha.FrameQualityError, "channel excess"):
            alpha.composite_quality(
                delivery,
                reference_rgba=reference,
                # Four pixels are below the ratio gate, so this assertion
                # specifically proves the bounded localized-excess gate.
                max_green_fringe_ratio=1.0,
            )

    def test_composite_quality_allows_faithful_saturated_green_and_magenta(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        reference = np.zeros((12, 12, 4), dtype=np.uint8)
        reference[3:9, 3:9, 3] = 96
        reference[4:8, 4:8, :3] = (0, 255, 0)
        reference[4:8, 4:8, 3] = 255
        reference[3:9, 3:9, :3] = (0, 255, 0)
        reference[4:8, 4:8, :3] = (0, 255, 0)
        self.assertTrue(
            alpha.composite_quality(reference, reference_rgba=reference)[
                "quality_passed"
            ]
        )
        reference[3:9, 3:9, :3] = (255, 0, 255)
        reference[4:8, 4:8, :3] = (255, 0, 255)
        self.assertTrue(
            alpha.composite_quality(reference, reference_rgba=reference)[
                "quality_passed"
            ]
        )

    def test_composite_quality_rejects_contamination_against_clean_reference(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        reference = np.zeros((12, 12, 4), dtype=np.uint8)
        reference[4:8, 4:8, :3] = (150, 140, 130)
        reference[4:8, 4:8, 3] = 255
        delivery = reference.copy()
        delivery[3:9, 3:9, :3] = (0, 255, 0)
        delivery[3:9, 3:9, 3] = 96
        delivery[4:8, 4:8, :3] = reference[4:8, 4:8, :3]
        delivery[4:8, 4:8, 3] = 255
        with self.assertRaisesRegex(alpha.FrameQualityError, "introduced green fringe"):
            alpha.composite_quality(delivery, reference_rgba=reference)

    def test_frame_quality_allows_saturated_magenta_with_opaque_colour_support(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((12, 12, 4), dtype=np.uint8)
        rgba[4:8, 4:8, :3] = (255, 0, 255)
        rgba[4:8, 4:8, 3] = 255
        rgba[3:9, 3:9, :3] = (255, 0, 255)
        rgba[3:9, 3:9, 3] = 96
        rgba[4:8, 4:8, 3] = 255
        self.assertTrue(alpha.frame_quality(rgba)["quality_passed"])

    def test_frame_quality_rejects_unsupported_translucent_green_ring(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((12, 12, 4), dtype=np.uint8)
        rgba[4:8, 4:8, :3] = (150, 140, 130)
        rgba[4:8, 4:8, 3] = 255
        rgba[3:9, 3:9, :3] = (0, 255, 0)
        rgba[3:9, 3:9, 3] = 96
        rgba[4:8, 4:8, :3] = (150, 140, 130)
        rgba[4:8, 4:8, 3] = 255
        with self.assertRaisesRegex(alpha.FrameQualityError, "green edge ratio"):
            alpha.frame_quality(rgba)

    def test_frame_quality_accepts_supported_translucent_green_ring(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((12, 12, 4), dtype=np.uint8)
        rgba[4:8, 4:8, :3] = (0, 255, 0)
        rgba[4:8, 4:8, 3] = 255
        rgba[3:9, 3:9, :3] = (0, 255, 0)
        rgba[3:9, 3:9, 3] = 96
        rgba[4:8, 4:8, 3] = 255
        self.assertTrue(alpha.frame_quality(rgba)["quality_passed"])

    def test_frame_quality_rejects_four_severe_unsupported_green_pixels_when_ratio_is_diluted(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((64, 64, 4), dtype=np.uint8)
        rgba[1:-1, 1:-1, :3] = (120, 128, 136)
        rgba[1:-1, 1:-1, 3] = 128
        rgba[20:22, 20:22, :3] = (0, 255, 0)
        with self.assertRaisesRegex(alpha.FrameQualityError, "channel excess"):
            alpha.frame_quality(rgba, max_green_edge_ratio=1.0)

    def test_delivery_edge_ratio_stays_strict_when_source_effects_are_relaxed(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        reference = np.zeros((12, 12, 4), dtype=np.uint8)
        reference[4:6, 1:11, :3] = (128, 128, 128)
        reference[4:6, 1:11, 3] = 64
        delivery = reference.copy()
        delivery[4, 1:3, :3] = (208, 128, 208)

        self.assertTrue(
            alpha.frame_quality(
                delivery,
                reference_rgba=reference,
                max_magenta_edge_ratio=alpha.DEFAULT_MAX_SOURCE_EDGE_RATIO,
            )["quality_passed"]
        )
        self.assertTrue(
            alpha.composite_quality(delivery, reference_rgba=reference)[
                "quality_passed"
            ]
        )
        with self.assertRaisesRegex(alpha.FrameQualityError, "magenta edge ratio"):
            alpha.frame_quality(
                delivery,
                reference_rgba=reference,
                max_magenta_edge_ratio=alpha.DEFAULT_MAX_DELIVERY_EDGE_RATIO,
                source_edge_alpha_floor=alpha.DEFAULT_DELIVERY_EDGE_ALPHA_FLOOR,
            )

    def test_low_alpha_rgb_bleed_repairs_clipped_magenta_without_changing_alpha(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        rgba = np.zeros((9, 9, 4), dtype=np.uint8)
        rgba[3:6, 3:6, :3] = (120, 128, 136)
        rgba[3:6, 3:6, 3] = 255
        rgba[2:7, 2:7, :3] = (255, 0, 255)
        rgba[2:7, 2:7, 3] = 64
        rgba[3:6, 3:6, 3] = 255
        rgba[3:6, 3:6, :3] = (120, 128, 136)
        before_alpha = rgba[:, :, 3].copy()
        repaired = alpha._bleed_edge_rgb(rgba, source_alpha=80, radius=2)
        self.assertTrue(bool(np.array_equal(repaired[:, :, 3], before_alpha)))
        self.assertTrue(bool(np.all(repaired[2:7, 2:7, :3] == (120, 128, 136))))
        self.assertTrue(alpha.frame_quality(repaired)["quality_passed"])

    def test_low_alpha_rgb_bleed_repairs_distance_three_without_expanding_hue_support(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        self.assertEqual(alpha.DEFAULT_EDGE_RGB_BLEED_RADIUS, 3)
        self.assertEqual(alpha.DEFAULT_EDGE_HUE_SUPPORT_RADIUS, 2)
        rgba = np.zeros((11, 11, 4), dtype=np.uint8)
        rgba[5, 5, :3] = (178, 177, 121)
        rgba[5, 5, 3] = 125
        rgba[5, 8, :3] = (231, 142, 211)
        rgba[5, 8, 3] = 64
        before_alpha = rgba[:, :, 3].copy()

        radius_two = alpha._bleed_edge_rgb(rgba, source_alpha=80, radius=2)
        with self.assertRaisesRegex(alpha.FrameQualityError, "channel excess"):
            alpha.frame_quality(
                radius_two,
                max_magenta_edge_ratio=1.0,
                max_magenta_edge_excess=64,
            )

        repaired = alpha._bleed_edge_rgb(rgba)
        self.assertTrue(bool(np.array_equal(repaired[:, :, 3], before_alpha)))
        self.assertEqual(repaired[5, 8, :3].tolist(), [178, 177, 121])
        self.assertTrue(
            alpha.frame_quality(repaired, max_magenta_edge_ratio=1.0)[
                "quality_passed"
            ]
        )

    def test_preclean_matte_rejects_foreground_touching_outer_edge(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        frame = np.full((24, 24, 3), (4, 240, 4), dtype=np.uint8)
        frame[:, 0, :] = (220, 30, 30)
        diagnostics = {}
        with self.assertRaisesRegex(alpha.FrameQualityError, "touches outer frame edge"):
            alpha.matte_frame(
                frame,
                diagnostics=diagnostics,
                reject_edge_contact=True,
            )
        self.assertGreater(diagnostics["preclean_outer_edge_alpha_maximum"], 20)
        self.assertGreater(diagnostics["preclean_outer_edge_contact_pixels"], 0)

    def test_default_matte_records_edge_contact_and_clears_output_border(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        frame = np.full((24, 24, 3), (4, 240, 4), dtype=np.uint8)
        frame[-1, 10:14, :] = (220, 30, 30)
        diagnostics = {}
        rgba = alpha.matte_frame(
            frame,
            diagnostics=diagnostics,
        )
        self.assertGreater(diagnostics["preclean_outer_edge_contact_pixels"], 0)
        self.assertEqual(int(rgba[0, :, 3].max()), 0)
        self.assertEqual(int(rgba[-1, :, 3].max()), 0)

    def test_edge_contact_diagnostics_count_corner_pixels_once(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        frame = np.full((24, 24, 3), (4, 240, 4), dtype=np.uint8)
        frame[0, 0, :] = (220, 30, 30)
        frame[0, -1, :] = (220, 30, 30)
        frame[-1, 0, :] = (220, 30, 30)
        frame[-1, -1, :] = (220, 30, 30)
        diagnostics = {}
        alpha.matte_frame(frame, diagnostics=diagnostics)
        self.assertEqual(diagnostics["preclean_outer_edge_contact_pixels"], 4)

    def test_compare_alpha_planes_rejects_lost_meaningful_foreground(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        expected = np.array([[0, 64], [255, 128]], dtype=np.uint8)
        actual = np.array([[0, 0], [255, 128]], dtype=np.uint8)
        with self.assertRaisesRegex(alpha.FrameQualityError, "lost meaningful"):
            alpha.compare_alpha_planes(
                expected,
                actual,
                max_mean_abs_error=32.0,
                max_p95_abs_error=255.0,
                max_abs_error=255,
            )

    def test_compare_alpha_planes_allows_isolated_codec_fringe_below_threshold(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        self.assertEqual(alpha.DEFAULT_ALPHA_LOSS_THRESHOLD, 20)
        tolerated = alpha.compare_alpha_planes(
            np.array([[18]], dtype=np.uint8),
            np.array([[0]], dtype=np.uint8),
            max_mean_abs_error=255.0,
            max_p95_abs_error=255.0,
            max_abs_error=255,
        )
        self.assertEqual(tolerated["lost_alpha_pixels"], 0)
        with self.assertRaisesRegex(alpha.FrameQualityError, "lost meaningful"):
            alpha.compare_alpha_planes(
                np.array([[21]], dtype=np.uint8),
                np.array([[0]], dtype=np.uint8),
                max_mean_abs_error=255.0,
                max_p95_abs_error=255.0,
                max_abs_error=255,
            )

    def test_dry_run_report_commands_are_path_free(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source.mp4"
            source.write_bytes(b"not-video")
            report = Path(temp) / "run.report.json"
            payload = {
                "commands": converter._safe_command(
                    alpha.build_ffmpeg_decode_command(
                        "/Users/example/private/source.mp4",
                        width=16,
                        height=16,
                        ffmpeg="/opt/homebrew/bin/ffmpeg",
                    )
                )
            }
            converter._write_json(report, payload, replace=False)
            text = report.read_text(encoding="utf-8")
            self.assertNotIn("/Users/example", text)
            self.assertNotIn("/opt/homebrew", text)
            self.assertIn("source.mp4", text)

    def test_publication_failure_restores_old_artifact_report_pair(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "idle.mov"
            intermediate = root / "idle.prores4444.mov"
            report = root / "idle.report.json"
            output.write_bytes(b"old-output")
            intermediate.write_bytes(b"old-intermediate")
            report.write_text('{"status":"old"}\n', encoding="utf-8")
            staged_output = root / "staged-output.mov"
            staged_intermediate = root / "staged-intermediate.mov"
            staged_output.write_bytes(b"new-output")
            staged_intermediate.write_bytes(b"new-intermediate")
            original_replace = converter.os.replace
            injected = False

            def replace_with_injected_report_failure(source, target):
                nonlocal injected
                if Path(target) == report and not injected:
                    injected = True
                    raise OSError("injected report publication failure")
                return original_replace(source, target)

            with mock.patch.object(
                converter.os, "replace", side_effect=replace_with_injected_report_failure
            ):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "publication"
                ):
                    converter._publish_transaction(
                        staged_output,
                        output,
                        staged_intermediate,
                        intermediate,
                        report,
                        {"status": "converted"},
                        replace=True,
                    )
            self.assertEqual(output.read_bytes(), b"old-output")
            self.assertEqual(intermediate.read_bytes(), b"old-intermediate")
            self.assertEqual(report.read_text(encoding="utf-8"), '{"status":"old"}\n')

    def test_converter_composite_gate_aborts_before_publication(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            output = root / "idle.mov"
            intermediate = root / "idle.prores4444.mov"
            report = root / "idle.report.json"
            source.write_bytes(b"source")
            output.write_bytes(b"old-output")
            intermediate.write_bytes(b"old-intermediate")
            report.write_text('{"status":"old"}\n', encoding="utf-8")
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(output),
                    "--report",
                    str(report),
                    "--intermediate-output",
                    str(intermediate),
                    "--replace",
                ]
            )
            info = alpha.VideoInfo(
                width=4,
                height=4,
                frame_count=1,
                fps=Fraction(24, 1),
                duration_seconds=1 / 24,
                codec_name="h264",
                pixel_format="yuv444p",
            )

            def fake_probe(path, **_kwargs):
                if Path(path).name.startswith("intermediate"):
                    return alpha.VideoInfo(
                        width=4,
                        height=4,
                        frame_count=1,
                        fps=Fraction(24, 1),
                        duration_seconds=1 / 24,
                        codec_name="prores",
                        pixel_format="yuva444p10le",
                        codec_profile="4444",
                    )
                return info

            def fake_stream(_source, stage, reference_alpha, **_kwargs):
                stage.write_bytes(b"intermediate")
                reference_alpha.write_bytes(b"\0" * 16)
                return {"frames_checked": 1, "quality_passed": True}

            def fake_avconvert(_source, stage, **_kwargs):
                stage.write_bytes(b"delivery")

            def failing_verification(*_args, **_kwargs):
                np = alpha.np
                clean = np.zeros((12, 12, 4), dtype=np.uint8)
                clean[4:8, 4:8, :3] = (150, 140, 130)
                clean[4:8, 4:8, 3] = 255
                contaminated = clean.copy()
                contaminated[3:9, 3:9, :3] = (0, 255, 0)
                contaminated[3:9, 3:9, 3] = 96
                contaminated[4:8, 4:8] = clean[4:8, 4:8]
                self.assertTrue(
                    alpha.frame_quality(
                        contaminated,
                        max_green_edge_ratio=1.0,
                        max_green_edge_excess=255,
                    )["quality_passed"]
                )
                alpha.composite_quality(contaminated, reference_rgba=clean)
                raise AssertionError("composite gate unexpectedly passed")

            publication = mock.Mock()
            with mock.patch.object(converter, "require_image_dependencies"), mock.patch.object(
                converter, "require_tool", return_value="tool"
            ), mock.patch.object(converter, "probe_video", side_effect=fake_probe), mock.patch.object(
                converter, "_stream_matte_to_prores", side_effect=fake_stream
            ), mock.patch.object(converter, "_run_avconvert", side_effect=fake_avconvert), mock.patch.object(
                converter, "_verify_alpha_roundtrip", side_effect=failing_verification
            ), mock.patch.object(converter, "_publish_transaction", publication):
                with self.assertRaisesRegex(
                    alpha.FrameQualityError, "introduced green fringe"
                ):
                    converter.convert_video(args)
            publication.assert_not_called()
            self.assertEqual(output.read_bytes(), b"old-output")
            self.assertEqual(intermediate.read_bytes(), b"old-intermediate")
            self.assertEqual(report.read_text(encoding="utf-8"), '{"status":"old"}\n')

    def test_post_commit_backup_cleanup_oserror_warns_but_preserves_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "idle.mov"
            report = root / "idle.report.json"
            staged_output = root / "staged-output.mov"
            output.write_bytes(b"old-output")
            staged_output.write_bytes(b"new-output")
            original_unlink = Path.unlink
            reserved = False

            def unlink_with_cleanup_failure(path, *args, **kwargs):
                nonlocal reserved
                if path.suffix == ".bak":
                    if not reserved:
                        reserved = True
                        return original_unlink(path, *args, **kwargs)
                    raise OSError("/Users/private/backup cleanup denied")
                return original_unlink(path, *args, **kwargs)

            with mock.patch.object(Path, "unlink", new=unlink_with_cleanup_failure):
                rendered_stderr = io.StringIO()
                with warnings.catch_warnings():
                    warnings.simplefilter("always")
                    with redirect_stderr(rendered_stderr):
                        converter._publish_transaction(
                            staged_output,
                            output,
                            None,
                            None,
                            report,
                            {"status": "converted", "source": "/Users/private/source.mp4"},
                            replace=True,
                        )
            self.assertEqual(output.read_bytes(), b"new-output")
            self.assertEqual(json.loads(report.read_text(encoding="utf-8"))["status"], "converted")
            warning_text = rendered_stderr.getvalue()
            self.assertIn("publication committed; unable to remove backup", warning_text)
            self.assertNotIn("/Users/private", warning_text)
            self.assertNotIn(str(root), warning_text)
            self.assertNotIn(str(Path(converter.__file__).parent), warning_text)

    def test_source_rehash_rejects_deterministic_mutation(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source.mp4"
            source.write_bytes(b"before")
            digest = converter._sha256_source_file(source)
            source.write_bytes(b"after")
            with self.assertRaisesRegex(
                converter.AlphaConversionError, "source video changed"
            ):
                converter._assert_source_unchanged(source, digest)

    def test_source_digest_hashes_normal_nonempty_mp4(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source.mp4"
            payload = b"normal-mp4-source"
            source.write_bytes(payload)

            self.assertEqual(
                converter._sha256_source_file(source),
                hashlib.sha256(payload).hexdigest(),
            )

    def test_source_digest_rejects_symlink_fifo_and_nonregular_without_path_leak(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            regular = root / "private-source.mp4"
            regular.write_bytes(b"source")
            symlink = root / "private-symlink.mp4"
            symlink.symlink_to(regular)
            fifo = root / "private-source.fifo"
            os.mkfifo(fifo)
            directory = root / "private-directory"
            directory.mkdir()
            empty = root / "private-empty.mp4"
            empty.touch()

            candidates = [symlink, fifo, directory, empty]
            if Path("/dev/null").exists() and stat.S_ISCHR(
                Path("/dev/null").stat().st_mode
            ):
                candidates.append(Path("/dev/null"))

            for candidate in candidates:
                with self.subTest(candidate=candidate.name):
                    with mock.patch.object(
                        converter.os, "read", wraps=os.read
                    ) as source_read:
                        with self.assertRaisesRegex(
                            converter.AlphaConversionError,
                            "source video must be a non-empty regular file",
                        ) as raised:
                            converter._sha256_source_file(candidate)
                    source_read.assert_not_called()
                    rendered = str(raised.exception)
                    self.assertNotIn(str(root), rendered)
                    self.assertNotIn(str(candidate), rendered)
                    self.assertIsNone(raised.exception.__cause__)

    def test_source_digest_fifo_rejects_promptly_without_reader(self):
        with tempfile.TemporaryDirectory() as temp:
            fifo = Path(temp) / "unread-source.fifo"
            os.mkfifo(fifo)

            started = time.monotonic()
            with self.assertRaises(converter.AlphaConversionError):
                converter._sha256_source_file(fifo)
            elapsed = time.monotonic() - started

            self.assertLess(elapsed, 1.0)

    def test_convert_video_source_mutation_skips_publication_and_preserves_targets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            output = root / "idle.mov"
            intermediate = root / "idle.prores4444.mov"
            report = root / "idle.report.json"
            source.write_bytes(b"source-before")
            output.write_bytes(b"old-output")
            intermediate.write_bytes(b"old-intermediate")
            report.write_text('{"status":"old"}\n', encoding="utf-8")
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(output),
                    "--report",
                    str(report),
                    "--intermediate-output",
                    str(intermediate),
                    "--replace",
                ]
            )
            info = alpha.VideoInfo(
                width=4,
                height=4,
                frame_count=1,
                fps=Fraction(24, 1),
                duration_seconds=1 / 24,
                codec_name="h264",
                pixel_format="yuv444p",
            )

            def fake_probe(path, **_kwargs):
                if Path(path).name.startswith("intermediate"):
                    return alpha.VideoInfo(
                        width=4,
                        height=4,
                        frame_count=1,
                        fps=Fraction(24, 1),
                        duration_seconds=1 / 24,
                        codec_name="prores",
                        pixel_format="yuva444p10le",
                        codec_profile="4444",
                    )
                return info

            def fake_stream(_source, stage, reference_alpha, **_kwargs):
                stage.write_bytes(b"intermediate")
                reference_alpha.write_bytes(b"\0" * 16)
                return {"frames_checked": 1, "quality_passed": True}

            def fake_avconvert(_source, stage, **_kwargs):
                stage.write_bytes(b"delivery")

            def mutate_and_verify(*_args, **_kwargs):
                self.assertEqual(
                    _kwargs["max_green_edge_ratio"],
                    alpha.DEFAULT_MAX_DELIVERY_EDGE_RATIO,
                )
                self.assertEqual(
                    _kwargs["max_magenta_edge_ratio"],
                    alpha.DEFAULT_MAX_DELIVERY_EDGE_RATIO,
                )
                self.assertEqual(
                    _kwargs["source_edge_alpha_floor"],
                    alpha.DEFAULT_DELIVERY_EDGE_ALPHA_FLOOR,
                )
                source.write_bytes(b"source-mutated-during-conversion")
                return {"performed": True, "unsafe": False, "frames_verified": 1}

            publication = mock.Mock()
            with mock.patch.object(converter, "require_image_dependencies"), mock.patch.object(
                converter, "require_tool", return_value="tool"
            ), mock.patch.object(converter, "probe_video", side_effect=fake_probe), mock.patch.object(
                converter, "_stream_matte_to_prores", side_effect=fake_stream
            ), mock.patch.object(converter, "_run_avconvert", side_effect=fake_avconvert), mock.patch.object(
                converter, "_verify_alpha_roundtrip", side_effect=mutate_and_verify
            ), mock.patch.object(converter, "_publish_transaction", publication):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "source video changed"
                ):
                    converter.convert_video(args)
            publication.assert_not_called()
            self.assertEqual(output.read_bytes(), b"old-output")
            self.assertEqual(intermediate.read_bytes(), b"old-intermediate")
            self.assertEqual(report.read_text(encoding="utf-8"), '{"status":"old"}\n')

    def test_probe_rejects_variable_rate_before_decode(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            payload = {
                "streams": [
                    {
                        "codec_type": "video",
                        "codec_name": "h264",
                        "width": 16,
                        "height": 16,
                        "avg_frame_rate": "23/1",
                        "r_frame_rate": "24/1",
                        "nb_frames": "2",
                        "duration": "0.0833",
                    }
                ]
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps(payload), ""
            )
            with self.assertRaisesRegex(alpha.ProbeError, "constant frame rate"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=lambda *args, **kwargs: result,
                )

    def test_probe_records_audio_and_accepts_square_pixels(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            payload = {
                "streams": [
                    {
                        "codec_type": "video",
                        "codec_name": "h264",
                        "profile": "High",
                        "width": 16,
                        "height": 16,
                        "sample_aspect_ratio": "1:1",
                        "avg_frame_rate": "24/1",
                        "r_frame_rate": "24/1",
                        "nb_read_frames": "2",
                        "duration": "0.083333",
                    },
                    {"codec_type": "audio", "codec_name": "aac"},
                ]
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps(payload), ""
            )

            info = alpha.probe_video(
                source.name,
                ffprobe="/opt/homebrew/bin/ffprobe",
                runner=lambda *args, **kwargs: result,
            )

            self.assertEqual(info.sample_aspect_ratio, "1:1")
            self.assertEqual(info.audio_codecs, ("aac",))

    def test_probe_rejects_non_square_sample_aspect_ratio_before_decode(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            payload = {
                "streams": [
                    {
                        "codec_type": "video",
                        "codec_name": "h264",
                        "width": 16,
                        "height": 16,
                        "sample_aspect_ratio": "4:3",
                        "avg_frame_rate": "24/1",
                        "r_frame_rate": "24/1",
                        "nb_read_frames": "2",
                        "duration": "0.083333",
                    }
                ]
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps(payload), ""
            )

            with self.assertRaisesRegex(alpha.ProbeError, "square pixels"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=lambda *args, **kwargs: result,
                )

    def test_probe_ignores_attached_cover_art_but_rejects_two_playable_videos(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "codec_type": "video",
                "codec_name": "h264",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_frames": "2",
                "duration": "0.0833",
            }
            cover = dict(stream, disposition={"attached_pic": 1})
            payload = {"streams": [stream, cover]}
            def run_probe(*args, **kwargs):
                return subprocess.CompletedProcess(
                    ["ffprobe"], 0, json.dumps(payload), ""
                )

            info = alpha.probe_video(
                source.name,
                ffprobe="/opt/homebrew/bin/ffprobe",
                runner=run_probe,
            )
            self.assertEqual(info.frame_count, 2)

            payload["streams"].append(dict(stream))
            with self.assertRaisesRegex(alpha.ProbeError, "exactly one video stream"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=run_probe,
                )

    def test_missing_dependency_error_is_actionable(self):
        with mock.patch.object(alpha, "np", None), mock.patch.object(alpha, "Image", None):
            with self.assertRaisesRegex(alpha.MissingDependencyError, "NumPy"):
                alpha.require_image_dependencies()


@unittest.skipIf(alpha.np is None or alpha.Image is None, "NumPy and Pillow are required")
class MacOSAlphaSyntheticMatteTests(unittest.TestCase):
    def _synthetic_frame(self, *, green_offset: float = 0.0):
        np = alpha.np
        height, width = 40, 48
        yy, xx = np.mgrid[0:height, 0:width]
        background = np.empty((height, width, 3), dtype=np.float32)
        background[:, :, 0] = 22.0 + xx * 0.30 + green_offset
        background[:, :, 1] = 152.0 + yy * 0.80 + xx * 0.25 + green_offset
        background[:, :, 2] = 26.0 + yy * 0.25
        alpha_values = np.zeros((height, width), dtype=np.float32)
        alpha_values[12:28, 15:33] = 1.0
        alpha_values[11, 16:32] = 0.45
        alpha_values[28, 16:32] = 0.45
        alpha_values[12:28, 14] = 0.45
        alpha_values[12:28, 33] = 0.45
        foreground = np.zeros_like(background)
        foreground[:, :, :] = (220.0, 184.0, 170.0)
        # A slight green tint in the source foreground exercises despill.
        foreground[:, :, 1] += 26.0
        observed = background * (1.0 - alpha_values[:, :, None]) + foreground * alpha_values[:, :, None]
        return np.clip(observed, 0, 255).astype(np.uint8), alpha_values

    def test_background_surface_follows_nonuniform_border(self):
        frame, _ = self._synthetic_frame()
        background = alpha.estimate_background(frame)
        np = alpha.np
        self.assertGreater(float(np.std(background[:, :, 1])), 8.0)
        self.assertLess(float(np.abs(background[5, 6, 1] - background[5, 40, 1])), 15.0)

    def test_variable_green_frames_matte_to_transparent_edges_and_soft_alpha(self):
        frame_one, source_alpha = self._synthetic_frame(green_offset=0.0)
        frame_two, _ = self._synthetic_frame(green_offset=18.0)
        rgba_one = alpha.matte_frame(frame_one)
        rgba_two = alpha.matte_frame(frame_two)
        np = alpha.np
        self.assertEqual(int(rgba_one[:, :, 3].max()), 255)
        self.assertEqual(int(rgba_two[:, :, 3].max()), 255)
        self.assertEqual(int(rgba_one[0, :, 3].max()), 0)
        self.assertEqual(int(rgba_one[:, -1, 3].max()), 0)
        # Antialiased source boundaries must remain semitransparent rather than
        # being replaced by a binary/blurred silhouette.
        self.assertTrue(bool(np.any((rgba_one[:, :, 3] > 0) & (rgba_one[:, :, 3] < 255))))
        metrics = alpha.frame_quality(rgba_one, max_magenta_edge_ratio=0.5)
        self.assertTrue(metrics["quality_passed"])
        self.assertGreater(metrics["foreground_pixels"], 100)

    def test_despill_reduces_green_on_retained_foreground(self):
        frame, _ = self._synthetic_frame()
        rgba = alpha.matte_frame(frame, despill_strength=1.0, despill_allowance=0.0)
        np = alpha.np
        retained = rgba[:, :, 3] > 240
        green_excess = rgba[:, :, 1].astype(np.int16) - np.maximum(
            rgba[:, :, 0], rgba[:, :, 2]
        ).astype(np.int16)
        self.assertLessEqual(int(green_excess[retained].max()), 3)


@unittest.skipUnless(
    alpha.np is not None
    and alpha.Image is not None
    and shutil.which("ffmpeg")
    and shutil.which("ffprobe")
    and shutil.which("avconvert"),
    "NumPy/Pillow, ffmpeg, ffprobe, and macOS avconvert are required",
)
class MacOSAlphaIntegrationTests(unittest.TestCase):
    """Exercise the real ffmpeg -> avconvert -> avconvert -> ffmpeg path."""

    def _write_synthetic_source(self, path: Path) -> tuple[int, int, int]:
        np = alpha.np
        height, width, frame_count = 48, 64, 6
        yy, xx = np.mgrid[0:height, 0:width]
        frames = []
        for index in range(frame_count):
            # Spatially varying green prevents a fixed RGB key from passing.
            background = np.empty((height, width, 3), dtype=np.float32)
            background[:, :, 0] = 18.0 + xx * 0.32 + index * 0.4
            background[:, :, 1] = 146.0 + yy * 0.62 + xx * 0.24 + index * 1.8
            background[:, :, 2] = 24.0 + yy * 0.20
            center_x = 31.0 + index * 1.5
            center_y = 24.0
            distance = np.sqrt((xx - center_x) ** 2 + (yy - center_y) ** 2)
            alpha_values = np.clip((15.0 - distance) / 3.0, 0.0, 1.0)
            foreground = np.empty_like(background)
            foreground[:, :, :] = (220.0, 200.0, 180.0)
            # Slight green spill exercises despill without making the subject
            # itself a magenta-edge fixture.
            foreground[:, :, 1] += 12.0
            observed = background * (1.0 - alpha_values[:, :, None]) + foreground * alpha_values[:, :, None]
            frames.append(np.clip(observed, 0, 255).astype(np.uint8))
        path.write_bytes(np.stack(frames).tobytes())
        return width, height, frame_count

    def test_real_cli_roundtrip_verifies_all_frames_and_sanitizes_report(self):
        ffmpeg = shutil.which("ffmpeg")
        ffprobe = shutil.which("ffprobe")
        avconvert = shutil.which("avconvert")
        assert ffmpeg and ffprobe and avconvert
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            raw = temp_path / "synthetic.rgb"
            source = temp_path / "source.mp4"
            output = temp_path / "pet.mov"
            report = temp_path / "pet.report.json"
            intermediate = temp_path / "pet.prores4444.mov"
            width, height, frame_count = self._write_synthetic_source(raw)
            encode = subprocess.run(
                [
                    ffmpeg,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-f",
                    "rawvideo",
                    "-pix_fmt",
                    "rgb24",
                    "-s",
                    f"{width}x{height}",
                    "-r",
                    "24/1",
                    "-i",
                    str(raw),
                    "-an",
                    "-c:v",
                    "libx264",
                    "-crf",
                    "0",
                    "-pix_fmt",
                    "yuv444p",
                    str(source),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(encode.returncode, 0, encode.stderr)
            command = [
                sys.executable,
                str(ROOT / "tools" / "convert_codex_pet_macos_alpha.py"),
                str(source),
                str(output),
                "--report",
                str(report),
                "--intermediate-output",
                str(intermediate),
                "--width",
                "65",
                "--height",
                "49",
                "--ffmpeg",
                ffmpeg,
                "--ffprobe",
                ffprobe,
                "--avconvert",
                avconvert,
            ]
            converted = subprocess.run(
                command,
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(converted.returncode, 0, converted.stderr)
            payload = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(payload["status"], "converted")
            self.assertEqual(
                payload["source"]["audio"],
                {"stream_count": 0, "codecs": [], "policy": "none"},
            )
            self.assertTrue(payload["quality"]["loop_seam"]["performed"])
            self.assertEqual(
                payload["quality"]["loop_seam"]["policy"], "informational"
            )
            self.assertFalse(payload["quality"]["loop_seam"]["exact_match"])
            self.assertEqual(
                payload["geometry"],
                {"width": 64, "height": 48, "pixel_format": "straight-rgba"},
            )
            self.assertEqual(
                payload["geometry_alignment"],
                {
                    "requested_width": 65,
                    "requested_height": 49,
                    "policy": "floor_to_even",
                    "adjusted": True,
                },
            )
            verification = payload["verification"]
            self.assertTrue(verification["performed"])
            self.assertFalse(verification["unsafe"])
            self.assertEqual(verification["frames_verified"], frame_count)
            self.assertEqual(verification["delivery"]["codec"], "hevc")
            self.assertEqual(verification["delivery"]["frames"], frame_count)
            self.assertEqual(verification["delivery"]["fps"], "24/1")
            self.assertEqual(
                (verification["delivery"]["width"], verification["delivery"]["height"]),
                (64, 48),
            )
            self.assertEqual(verification["roundtrip"]["profile"], "4444")
            self.assertEqual(
                (verification["roundtrip"]["width"], verification["roundtrip"]["height"]),
                (64, 48),
            )
            self.assertEqual(verification["alpha"]["lost_alpha_pixels_total"], 0)
            self.assertLessEqual(
                verification["maximum_outer_edge_alpha"],
                alpha.DEFAULT_MAX_BORDER_ALPHA,
            )
            self.assertEqual(
                verification["alpha"]["tolerances"]["max_border_alpha"],
                alpha.DEFAULT_MAX_BORDER_ALPHA,
            )
            self.assertEqual(
                verification["composite"]["background_names"],
                ["white", "black", "checkerboard"],
            )
            self.assertEqual(verification["composite"]["frames_checked"], frame_count)
            self.assertLessEqual(
                verification["composite"]["maximum_introduced_green_fringe_ratio"],
                alpha.DEFAULT_MAX_GREEN_FRINGE_RATIO,
            )
            self.assertLessEqual(
                verification["composite"]["maximum_introduced_magenta_fringe_ratio"],
                alpha.DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
            )
            self.assertEqual(
                verification["composite"]["limits"]["max_introduced_green_fringe_ratio"],
                alpha.DEFAULT_MAX_GREEN_FRINGE_RATIO,
            )
            self.assertEqual(
                verification["composite"]["limits"]["max_introduced_magenta_fringe_ratio"],
                alpha.DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
            )
            self.assertIn("maximum_green_edge_ratio", payload["quality"])
            self.assertIn("maximum_magenta_edge_ratio", payload["quality"])
            self.assertEqual(payload["quality"]["preclean_outer_edge_alpha_maximum"], 0)
            self.assertEqual(payload["quality"]["preclean_outer_edge_contact_pixels"], 0)
            self.assertEqual(
                payload["artifacts"]["source_sha256"],
                hashlib.sha256(source.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                payload["artifacts"]["source_sha256_before_probe"],
                payload["artifacts"]["source_sha256_before_publication"],
            )
            self.assertEqual(
                payload["artifacts"]["output_sha256"],
                hashlib.sha256(output.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                payload["artifacts"]["intermediate_sha256"],
                hashlib.sha256(intermediate.read_bytes()).hexdigest(),
            )
            self.assertTrue(output.is_file())
            self.assertTrue(intermediate.is_file())
            report_text = report.read_text(encoding="utf-8")
            self.assertNotIn(str(ROOT), report_text)
            self.assertNotIn(str(temp_path.parent), report_text)

            # Existing outputs are immutable unless --replace is explicit.
            refused = subprocess.run(
                command,
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("pass --replace", refused.stderr)


if __name__ == "__main__":
    unittest.main()
