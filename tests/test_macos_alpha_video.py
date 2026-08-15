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
    def test_cli_accepts_an_already_owned_process_group(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "tools" / "convert_codex_pet_macos_alpha.py"),
                "--help",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
            start_new_session=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source constant-frame-rate MP4", result.stdout)

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
        self.assertEqual(events[0]["stage"], "prepare")
        self.assertEqual(events[0]["code"], "CONVERSION_FAILED")
        self.assertEqual(events[0]["safe_message"], "Conversion failed.")
        self.assertNotIn("/Users/example", stdout.getvalue())
        self.assertNotIn("/Users/example", stderr.getvalue())
        self.assertIn("error: <local-file>", stderr.getvalue())

    def test_progress_failure_taxonomy_is_stable_bounded_and_path_free(self):
        cases = (
            (alpha.MissingToolError("/Users/private/ffmpeg"), "TOOL_MISSING", "prepare"),
            (alpha.ProbeError("/Users/private/source.mp4"), "SOURCE_UNSUPPORTED", "probe"),
            (alpha.FrameQualityError("source frame 2 failed"), "QUALITY_GATE_FAILED", "matte"),
            (converter.AlphaConversionError("encoder timed out"), "PROCESS_TIMEOUT", "encode"),
            (converter.AlphaConversionError("insufficient disk"), "RESOURCE_LIMIT", "prepare"),
            (converter.AlphaConversionError("publication manifest invalid"), "PUBLICATION_FAILED", "publish"),
        )
        for exc, expected_code, expected_stage in cases:
            with self.subTest(code=expected_code):
                stream = io.StringIO()
                progress = converter._ProgressReporter(True, stream=stream)
                progress.emit(60, stage="encode", message="Encoding")
                progress.failed(exc)
                event = json.loads(stream.getvalue().splitlines()[-1])
                self.assertEqual(event["status"], "failed")
                self.assertEqual(event["code"], expected_code)
                self.assertEqual(event["stage"], expected_stage)
                self.assertLessEqual(len(event["safe_message"].encode("utf-8")), 256)
                self.assertNotIn("/Users/private", json.dumps(event))

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
        self.assertIn("bits_per_raw_sample", entries)
        self.assertIn("time_base", entries)
        self.assertIn("best_effort_timestamp_time", entries)
        self.assertIn("stream_index", entries)
        self.assertIn("media_type", entries)
        self.assertIn("stream_disposition=attached_pic", entries)
        self.assertIn("-show_frames", command)

    def test_ffmpeg_and_avconvert_commands_use_alpha_contract(self):
        decode = alpha.build_ffmpeg_decode_command(
            "/private/source.mp4", width=640, height=360, ffmpeg="ffmpeg-custom"
        )
        self.assertEqual(decode[0], "ffmpeg-custom")
        self.assertIn("-map", decode)
        self.assertEqual(decode[decode.index("-pix_fmt") + 1], "rgb24")
        self.assertEqual(decode[decode.index("-fps_mode") + 1], "passthrough")
        self.assertNotIn("-vsync", decode)
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
        self.assertEqual(
            roundtrip_decode[roundtrip_decode.index("-fps_mode") + 1],
            "passthrough",
        )
        self.assertNotIn("-vsync", roundtrip_decode)
        legacy_decode = alpha.build_ffmpeg_decode_command(
            "/private/source.mp4",
            width=640,
            height=360,
            frame_sync_mode="vsync",
        )
        self.assertEqual(legacy_decode[legacy_decode.index("-vsync") + 1], "0")
        self.assertNotIn("-fps_mode", legacy_decode)
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

    def test_verified_delivery_rejects_an_audio_stream(self):
        expected = alpha.VideoInfo(
            width=64,
            height=48,
            frame_count=6,
            fps=Fraction(24, 1),
            duration_seconds=0.25,
            codec_name="",
            pixel_format="",
        )
        actual = alpha.VideoInfo(
            width=64,
            height=48,
            frame_count=6,
            fps=Fraction(24, 1),
            duration_seconds=0.25,
            codec_name="hevc",
            pixel_format="yuv420p",
            audio_codecs=("aac",),
        )
        with self.assertRaisesRegex(alpha.FrameQualityError, "must be silent"):
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

    def test_matte_process_pair_closes_decoder_when_encoder_spawn_fails(self):
        decoder = mock.Mock()
        with mock.patch.object(
            converter,
            "_start_process",
            side_effect=[decoder, converter.AlphaConversionError("encoder failed")],
        ), mock.patch.object(converter, "close_process") as close_process:
            with self.assertRaisesRegex(converter.AlphaConversionError, "encoder failed"):
                converter._start_matte_process_pair(["decode"], ["encode"])
        close_process.assert_called_once_with(decoder)

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

    def test_allow_empty_frames_still_rejects_an_entirely_empty_animation(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        empty = np.zeros((4, 4, 4), dtype=np.uint8)
        info = alpha.VideoInfo(
            width=4,
            height=4,
            frame_count=1,
            fps=Fraction(24, 1),
            duration_seconds=1 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        decoder = mock.Mock()
        encoder = mock.Mock()
        encoder.stdin = mock.Mock()
        encoder.wait.return_value = 0

        def fake_matte(*_args, diagnostics, **_kwargs):
            diagnostics.update(
                preclean_outer_edge_alpha_maximum=0,
                preclean_outer_edge_contact_pixels=0,
            )
            return empty

        with tempfile.TemporaryDirectory() as temp:
            intermediate = Path(temp) / "intermediate.mov"
            intermediate.write_bytes(b"prores")
            with mock.patch.object(
                converter,
                "_start_matte_process_pair",
                return_value=(decoder, encoder),
            ), mock.patch.object(
                converter, "read_raw_frames", return_value=iter([object()])
            ), mock.patch.object(
                converter, "matte_frame", side_effect=fake_matte
            ), mock.patch.object(
                converter, "_write_all_with_deadline"
            ), mock.patch.object(converter, "close_process"):
                with self.assertRaisesRegex(
                    alpha.FrameQualityError,
                    "animation contains no foreground pixels",
                ):
                    converter._stream_matte_to_prores(
                        Path("source.mp4"),
                        intermediate,
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
                        allow_empty_frame=True,
                        reject_edge_contact=False,
                    )

    def test_allow_empty_frames_reports_empty_frames_when_foreground_exists(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        empty = np.zeros((4, 4, 4), dtype=np.uint8)
        foreground = empty.copy()
        foreground[2, 2] = (220, 180, 160, 255)
        outputs = iter([empty, foreground])
        info = alpha.VideoInfo(
            width=4,
            height=4,
            frame_count=2,
            fps=Fraction(24, 1),
            duration_seconds=2 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        decoder = mock.Mock()
        encoder = mock.Mock()
        encoder.stdin = mock.Mock()
        encoder.wait.return_value = 0

        def fake_matte(*_args, diagnostics, **_kwargs):
            diagnostics.update(
                preclean_outer_edge_alpha_maximum=0,
                preclean_outer_edge_contact_pixels=0,
            )
            return next(outputs)

        with tempfile.TemporaryDirectory() as temp:
            intermediate = Path(temp) / "intermediate.mov"
            intermediate.write_bytes(b"prores")
            with mock.patch.object(
                converter,
                "_start_matte_process_pair",
                return_value=(decoder, encoder),
            ), mock.patch.object(
                converter,
                "read_raw_frames",
                return_value=iter([object(), object()]),
            ), mock.patch.object(
                converter, "matte_frame", side_effect=fake_matte
            ), mock.patch.object(
                converter, "_write_all_with_deadline"
            ), mock.patch.object(converter, "close_process"):
                report = converter._stream_matte_to_prores(
                    Path("source.mp4"),
                    intermediate,
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
                    allow_empty_frame=True,
                    reject_edge_contact=False,
                )

        self.assertEqual(report["empty_frames"], 1)
        self.assertEqual(report["maximum_consecutive_empty_frames"], 1)
        self.assertGreater(report["foreground_pixels"], 0)

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

    def test_publication_stages_artifacts_next_to_targets_with_private_permissions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            work = root / "work"
            target = root / "target"
            work.mkdir()
            target.mkdir()
            output_stage = work / "output.mov"
            output_stage.write_bytes(b"delivery")
            output = target / "idle.mov"
            report = target / "idle.report.json"

            converter._publish_transaction(
                output_stage,
                output,
                None,
                None,
                report,
                {"status": "converted"},
                replace=False,
            )

            self.assertEqual(output.read_bytes(), b"delivery")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)

    def test_publication_crash_recovery_restores_every_rename_boundary(self):
        for crash_after in range(1, 7):
            with self.subTest(crash_after=crash_after), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                output = root / "idle.mov"
                intermediate = root / "idle.prores.mov"
                report = root / "idle.report.json"
                output.write_bytes(b"old-output")
                intermediate.write_bytes(b"old-intermediate")
                report.write_text('{"status":"old"}\n', encoding="utf-8")
                staged_output = root / "new-output.mov"
                staged_intermediate = root / "new-intermediate.mov"
                staged_output.write_bytes(b"new-output")
                staged_intermediate.write_bytes(b"new-intermediate")

                with self.assertRaises(converter._InjectedPublicationCrash):
                    converter._publish_transaction(
                        staged_output,
                        output,
                        staged_intermediate,
                        intermediate,
                        report,
                        {"status": "converted"},
                        replace=True,
                        _crash_after_rename=crash_after,
                    )
                manifest = converter._transaction_manifest_path(report)
                self.assertTrue(manifest.is_file())
                self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)

                converter._recover_publish_transaction(output, intermediate, report)

                self.assertEqual(output.read_bytes(), b"old-output")
                self.assertEqual(intermediate.read_bytes(), b"old-intermediate")
                self.assertEqual(report.read_text(encoding="utf-8"), '{"status":"old"}\n')
                self.assertFalse(manifest.exists())
                self.assertFalse(any(path.suffix in {".tmp", ".bak"} for path in root.iterdir()))

    def test_convert_retry_recovers_partial_publication_before_collision_check(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            source.write_bytes(b"source")
            output = root / "idle.mov"
            intermediate = root / "idle.prores.mov"
            report = root / "idle.report.json"
            staged = root / "staged.mov"
            staged_intermediate = root / "staged.prores.mov"
            staged.write_bytes(b"new-output")
            staged_intermediate.write_bytes(b"new-intermediate")
            with self.assertRaises(converter._InjectedPublicationCrash):
                converter._publish_transaction(
                    staged,
                    output,
                    staged_intermediate,
                    intermediate,
                    report,
                    {"status": "converted"},
                    replace=False,
                    _crash_after_rename=2,
                )
            self.assertTrue(output.exists())
            self.assertTrue(intermediate.exists())
            manifest = converter._transaction_manifest_path(report)
            before = {
                "output": output.read_bytes(),
                "intermediate": intermediate.read_bytes(),
                "manifest": manifest.read_bytes(),
            }

            args = converter.build_parser().parse_args([str(source), str(output)])
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "_check_target_collisions"
            ) as collision:
                with self.assertRaisesRegex(
                    converter.AlphaConversionError,
                    "identical artifact path flags",
                ):
                    converter.convert_video(args)
            collision.assert_not_called()
            self.assertEqual(output.read_bytes(), before["output"])
            self.assertEqual(intermediate.read_bytes(), before["intermediate"])
            self.assertEqual(manifest.read_bytes(), before["manifest"])

            converter._recover_publish_transaction(output, intermediate, report)
            self.assertFalse(output.exists())
            self.assertFalse(intermediate.exists())
            self.assertFalse(report.exists())
            self.assertFalse(manifest.exists())

    def test_invalid_publication_manifest_fails_closed_without_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "idle.mov"
            report = root / "idle.report.json"
            planted = root / "other.mov"
            planted_stage = root / ".other.mov.x.tmp"
            planted.write_bytes(b"do-not-touch")
            planted_stage.write_bytes(b"do-not-touch-stage")
            manifest = converter._transaction_manifest_path(report)
            manifest.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "committed": False,
                        "entries": [
                            {
                                "target": str(planted),
                                "stage": str(planted_stage),
                                "backup": str(root / ".other.mov.x.bak"),
                                "had_target": False,
                                "sha256": "0" * 64,
                            },
                            {
                                "target": str(report),
                                "stage": str(root / ".idle.report.json.x.tmp"),
                                "backup": str(root / ".idle.report.json.x.bak"),
                                "had_target": False,
                                "sha256": "0" * 64,
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            manifest.chmod(0o600)
            with self.assertRaisesRegex(
                converter.AlphaConversionError, "manifest is invalid"
            ) as raised:
                converter._recover_publish_transaction(output, None, report)
            self.assertNotIn(temp, str(raised.exception))
            self.assertEqual(planted.read_bytes(), b"do-not-touch")
            self.assertEqual(planted_stage.read_bytes(), b"do-not-touch-stage")
            self.assertTrue(manifest.exists())

    def test_recovery_manifest_rejects_symlink_links_and_nonprivate_mode(self):
        for mutation in ("symlink", "hardlink", "mode"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                output = root / "idle.mov"
                report = root / "idle.report.json"
                staged = root / "staged.mov"
                staged.write_bytes(b"new-output")
                with self.assertRaises(converter._InjectedPublicationCrash):
                    converter._publish_transaction(
                        staged,
                        output,
                        None,
                        None,
                        report,
                        {"status": "converted"},
                        replace=False,
                        _crash_after_rename=1,
                    )
                manifest = converter._transaction_manifest_path(report)
                if mutation == "symlink":
                    actual = root / "actual-manifest.json"
                    manifest.replace(actual)
                    manifest.symlink_to(actual)
                elif mutation == "hardlink":
                    os.link(manifest, root / "manifest-hardlink.json")
                else:
                    manifest.chmod(0o644)
                before = output.read_bytes()
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "manifest is invalid"
                ):
                    converter._recover_publish_transaction(output, None, report)
                self.assertEqual(output.read_bytes(), before)

    def test_recovery_rejects_planted_private_artifacts_without_touching_unrelated_files(self):
        for mutation in ("stage-symlink", "stage-hardlink", "backup-symlink", "extra", "dir-symlink"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                output = root / "idle.mov"
                report = root / "idle.report.json"
                output.write_bytes(b"old-output")
                report.write_text('{"status":"old"}\n', encoding="utf-8")
                staged = root / "staged.mov"
                staged.write_bytes(b"new-output")
                unrelated = root / "unrelated.data"
                unrelated.write_bytes(b"do-not-touch")
                with self.assertRaises(converter._InjectedPublicationCrash):
                    converter._publish_transaction(
                        staged,
                        output,
                        None,
                        None,
                        report,
                        {"status": "converted"},
                        replace=True,
                        _crash_after_rename=1,
                    )
                manifest = converter._transaction_manifest_path(report)
                payload = json.loads(manifest.read_text(encoding="utf-8"))
                entry = payload["entries"][0]
                directory = Path(entry["directory"])
                stage_path = directory / entry["stage_name"]
                backup_path = directory / entry["backup_name"]
                if mutation == "stage-symlink":
                    stage_path.unlink()
                    stage_path.symlink_to(unrelated)
                elif mutation == "stage-hardlink":
                    stage_path.unlink()
                    os.link(unrelated, stage_path)
                elif mutation == "backup-symlink":
                    backup_path.unlink()
                    backup_path.symlink_to(unrelated)
                elif mutation == "extra":
                    (directory / "planted").write_bytes(b"planted")
                else:
                    actual_directory = root / "saved-transaction-directory"
                    directory.replace(actual_directory)
                    directory.symlink_to(actual_directory, target_is_directory=True)
                with self.assertRaisesRegex(
                    converter.AlphaConversionError,
                    "publication recovery",
                ):
                    converter._recover_publish_transaction(output, None, report)
                self.assertEqual(unrelated.read_bytes(), b"do-not-touch")
                self.assertTrue(manifest.exists())

    def test_pre_manifest_failure_removes_all_sibling_stages(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "idle.mov"
            report = root / "idle.report.json"
            output.write_bytes(b"old")
            staged = root / "staged.mov"
            staged.write_bytes(b"new")
            with mock.patch.object(
                converter,
                "_transaction_directory_identity",
                side_effect=converter.AlphaConversionError("injected backup failure"),
            ):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "injected backup failure"
                ):
                    converter._publish_transaction(
                        staged,
                        output,
                        None,
                        None,
                        report,
                        {"status": "converted"},
                        replace=True,
                    )
            self.assertFalse(any(path.name.startswith(".statelet-") for path in root.iterdir()))
            self.assertFalse(converter._transaction_manifest_path(report).exists())

    def test_cross_volume_stage_copy_detects_silent_corruption(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mov"
            target = root / "target.mov"
            source.write_bytes(b"verified-source")

            def corrupt_copy(_source, destination, **_kwargs):
                destination.write(b"silent-corruption")

            with mock.patch.object(
                converter.shutil, "copyfileobj", side_effect=corrupt_copy
            ):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "digest mismatch"
                ):
                    converter._stage_artifact_for_target(source, target)
            self.assertFalse(any(path.suffix == ".tmp" for path in root.iterdir()))

    def test_final_target_digest_corruption_rolls_back_before_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "idle.mov"
            report = root / "idle.report.json"
            output.write_bytes(b"old-output")
            report.write_text('{"status":"old"}\n', encoding="utf-8")
            staged = root / "staged.mov"
            staged.write_bytes(b"new-output")
            expected_digest = hashlib.sha256(b"new-output").hexdigest()
            original_replace = converter._durable_replace

            def replace_then_corrupt(source, target):
                original_replace(source, target)
                if Path(target) == output and Path(source).name == "stage-0":
                    output.write_bytes(b"corrupted-after-rename")

            with mock.patch.object(
                converter, "_durable_replace", side_effect=replace_then_corrupt
            ):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "digest mismatch"
                ):
                    converter._publish_transaction(
                        staged,
                        output,
                        None,
                        None,
                        report,
                        {
                            "status": "converted",
                            "artifacts": {"output_sha256": expected_digest},
                        },
                        replace=True,
                    )
            self.assertEqual(output.read_bytes(), b"old-output")
            self.assertEqual(report.read_text(encoding="utf-8"), '{"status":"old"}\n')

    def test_report_artifact_digest_mismatch_rejects_before_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "idle.mov"
            report = root / "idle.report.json"
            staged = root / "staged.mov"
            staged.write_bytes(b"verified-output")
            with self.assertRaisesRegex(
                converter.AlphaConversionError, "does not match report digest"
            ):
                converter._publish_transaction(
                    staged,
                    output,
                    None,
                    None,
                    report,
                    {
                        "status": "converted",
                        "artifacts": {"output_sha256": "0" * 64},
                    },
                    replace=False,
                )
            self.assertFalse(output.exists())
            self.assertFalse(report.exists())
            self.assertFalse(converter._transaction_manifest_path(report).exists())

    def test_avconvert_timeout_is_bounded_and_path_private(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with mock.patch.object(
                converter.alpha_engine,
                "_run_bounded_capture",
                side_effect=alpha.ProbeError("avconvert timed out"),
            ):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError,
                    "avconvert timed out",
                ) as raised:
                    converter._run_avconvert(
                        root / "private.mov",
                        root / "output.mov",
                        avconvert="avconvert",
                        preset=converter.DEFAULT_PRESET,
                        timeout_seconds=1,
                    )
            self.assertNotIn(str(root), str(raised.exception))

    def test_roundtrip_metric_aggregation_is_bounded_across_many_frames(self):
        accumulator = converter._RoundtripMetricsAccumulator()
        background = {
            "green_fringe_ratio": 0.01,
            "magenta_fringe_ratio": 0.02,
            "introduced_green_fringe_ratio": 0.003,
            "introduced_magenta_fringe_ratio": 0.004,
            "green_fringe_pixels": 2,
            "green_fringe_max_excess": 20,
            "introduced_green_fringe_max_excess": 12,
            "magenta_fringe_pixels": 3,
            "magenta_fringe_max_excess": 22,
            "introduced_magenta_fringe_max_excess": 14,
        }
        comparison = {
            "mean_absolute_error": 1.0,
            "p95_absolute_error": 2.0,
            "maximum_absolute_error": 3,
            "lost_alpha_pixels": 0,
        }
        composite = {
            "background_names": ["white", "black", "checkerboard"],
            "backgrounds": {
                name: dict(background)
                for name in ("white", "black", "checkerboard")
            },
            "maximum_delivery_green_fringe_ratio": 0.01,
            "maximum_delivery_magenta_fringe_ratio": 0.02,
            "maximum_introduced_green_fringe_ratio": 0.003,
            "maximum_introduced_magenta_fringe_ratio": 0.004,
            "maximum_introduced_green_fringe_excess": 12,
            "maximum_introduced_magenta_fringe_excess": 14,
        }
        for _ in range(10_000):
            accumulator.add(comparison, composite)

        self.assertEqual(accumulator.frames, 10_000)
        self.assertEqual(
            accumulator.backgrounds["white"]["green_fringe_pixels_total"],
            20_000,
        )
        self.assertFalse(
            any(isinstance(value, list) for value in vars(accumulator).values())
        )
        self.assertEqual(
            accumulator.snapshot(),
            {
                "frames": 10_000,
                "backgrounds": accumulator.backgrounds,
                "composite_maxima": {
                    "maximum_delivery_green_fringe_ratio": 0.01,
                    "maximum_delivery_magenta_fringe_ratio": 0.02,
                    "maximum_introduced_green_fringe_ratio": 0.003,
                    "maximum_introduced_magenta_fringe_ratio": 0.004,
                    "maximum_introduced_green_fringe_excess": 12,
                    "maximum_introduced_magenta_fringe_excess": 14,
                },
                "alpha": {
                    "mean_absolute_error_max": 1.0,
                    "p95_absolute_error_max": 2.0,
                    "maximum_absolute_error_max": 3,
                    "lost_alpha_pixels_total": 0,
                },
            },
        )

    def test_resource_preflight_enforces_every_configurable_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            source.write_bytes(b"x" * 11)
            base = alpha.VideoInfo(
                width=10,
                height=10,
                frame_count=10,
                fps=Fraction(24, 1),
                duration_seconds=10 / 24,
                codec_name="h264",
                pixel_format="yuv420p",
            )
            defaults = {
                "width": 10,
                "height": 10,
                "max_source_bytes": 11,
                "max_source_pixels": 100,
                "max_source_frames": 10,
                "max_source_duration_seconds": 10 / 24,
                "max_source_fps": 24.0,
                "min_free_disk_bytes": 1,
            }
            cases = (
                ("size", base, {"max_source_bytes": 10}, "size budget"),
                (
                    "pixels",
                    alpha.VideoInfo(**{**vars(base), "width": 11}),
                    {},
                    "pixel budget",
                ),
                (
                    "frames",
                    alpha.VideoInfo(**{**vars(base), "frame_count": 11}),
                    {},
                    "frame budget",
                ),
                (
                    "duration",
                    alpha.VideoInfo(**{**vars(base), "duration_seconds": 1.0}),
                    {},
                    "duration budget",
                ),
                (
                    "fps",
                    alpha.VideoInfo(**{**vars(base), "fps": Fraction(25, 1)}),
                    {},
                    "frame-rate budget",
                ),
            )
            with mock.patch.object(
                converter.shutil,
                "disk_usage",
                return_value=mock.Mock(free=10**12),
            ):
                # Exact configured limits are accepted.
                accepted = converter._preflight_resources(
                    source,
                    root / "out.mov",
                    root / "out.report.json",
                    None,
                    base,
                    **defaults,
                )
                self.assertTrue(accepted["passed"])
                for label, info, overrides, message in cases:
                    with self.subTest(label=label), self.assertRaisesRegex(
                        converter.AlphaConversionError, message
                    ):
                        converter._preflight_resources(
                            source,
                            root / "out.mov",
                            root / "out.report.json",
                            None,
                            info,
                            **{**defaults, **overrides},
                        )

    def test_peak_disk_model_aggregates_shared_targets_and_separates_volumes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "output" / "pet.mov"
            report = root / "report" / "pet.report.json"
            intermediate = root / "intermediate" / "pet.prores.mov"
            output.parent.mkdir()
            report.parent.mkdir()
            intermediate.parent.mkdir()
            info = alpha.VideoInfo(
                width=4,
                height=4,
                frame_count=2,
                fps=Fraction(24, 1),
                duration_seconds=2 / 24,
                codec_name="h264",
                pixel_format="yuv420p",
            )
            temp_root = Path(tempfile.gettempdir())

            shared_devices = {
                temp_root: 10,
                output.parent: 20,
                report.parent: 20,
                intermediate.parent: 30,
            }
            with mock.patch.object(
                converter.os,
                "stat",
                side_effect=lambda path: mock.Mock(st_dev=shared_devices[Path(path)]),
            ), mock.patch.object(
                converter.shutil, "disk_usage", return_value=mock.Mock(free=10**12)
            ):
                shared = converter._check_peak_disk_capacity(
                    output,
                    report,
                    intermediate,
                    info=info,
                    width=4,
                    height=4,
                    reserve_bytes=100,
                )
            self.assertEqual(shared["volume_count"], 3)
            shared_target_volume = next(
                item
                for item in shared["volumes"]
                if "delivery-stage" in item["components"]
            )
            self.assertEqual(
                shared_target_volume["components"],
                ["delivery-stage", "report-stage"],
            )
            self.assertEqual(
                shared_target_volume["required_bytes"],
                100
                + converter._allocation_with_overhead(
                    2 * 4 * 4 * converter.HEVC_PEAK_BYTES_PER_PIXEL
                )
                + converter._allocation_with_overhead(
                    converter.REPORT_STAGE_RESERVE_BYTES
                ),
            )
            raw_simultaneous_bytes = 2 * 4 * 4 * (
                converter.PRORES_PEAK_BYTES_PER_PIXEL
                + converter.HEVC_PEAK_BYTES_PER_PIXEL
                + converter.ALPHA_REFERENCE_BYTES_PER_PIXEL
                + converter.PRORES_PEAK_BYTES_PER_PIXEL
            )
            temp_volume = next(
                item
                for item in shared["volumes"]
                if item["components"] == ["conversion-temp"]
            )
            self.assertGreater(
                temp_volume["required_bytes"] - 100,
                raw_simultaneous_bytes,
            )
            self.assertNotIn(str(root), json.dumps(shared))

            separate_devices = {
                temp_root: 10,
                output.parent: 20,
                report.parent: 30,
                intermediate.parent: 40,
            }
            with mock.patch.object(
                converter.os,
                "stat",
                side_effect=lambda path: mock.Mock(st_dev=separate_devices[Path(path)]),
            ), mock.patch.object(
                converter.shutil, "disk_usage", return_value=mock.Mock(free=10**12)
            ):
                separate = converter._check_peak_disk_capacity(
                    output,
                    report,
                    intermediate,
                    info=info,
                    width=4,
                    height=4,
                    reserve_bytes=100,
                )
            self.assertEqual(separate["volume_count"], 4)
            self.assertEqual(
                separate["total_required_bytes"],
                shared["total_required_bytes"] + 100,
            )

    def test_peak_disk_model_accepts_exact_boundary_and_rejects_one_byte_less(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "output" / "pet.mov"
            report = root / "report" / "pet.report.json"
            output.parent.mkdir()
            report.parent.mkdir()
            info = alpha.VideoInfo(
                width=8,
                height=6,
                frame_count=3,
                fps=Fraction(24, 1),
                duration_seconds=3 / 24,
                codec_name="h264",
                pixel_format="yuv420p",
            )
            locations = {
                Path(tempfile.gettempdir()): 10,
                output.parent: 20,
                report.parent: 30,
            }
            stat_side_effect = lambda path: mock.Mock(st_dev=locations[Path(path)])
            with mock.patch.object(
                converter.os, "stat", side_effect=stat_side_effect
            ), mock.patch.object(
                converter.shutil, "disk_usage", return_value=mock.Mock(free=10**12)
            ):
                measured = converter._check_peak_disk_capacity(
                    output,
                    report,
                    None,
                    info=info,
                    width=8,
                    height=6,
                    reserve_bytes=256,
                )
            required_by_device = {
                device: item["required_bytes"]
                for device, item in zip(
                    sorted(set(locations.values())), measured["volumes"]
                )
            }
            self.assertEqual(
                len(required_by_device),
                len(set(locations.values())),
            )

            def exact_disk_usage(path):
                return mock.Mock(free=required_by_device[locations[Path(path)]])

            with mock.patch.object(
                converter.os, "stat", side_effect=stat_side_effect
            ), mock.patch.object(
                converter.shutil, "disk_usage", side_effect=exact_disk_usage
            ):
                accepted = converter._check_peak_disk_capacity(
                    output,
                    report,
                    None,
                    info=info,
                    width=8,
                    height=6,
                    reserve_bytes=256,
                )
            self.assertEqual(accepted["total_required_bytes"], measured["total_required_bytes"])

            def short_disk_usage(path):
                device = locations[Path(path)]
                free = required_by_device[device] - (1 if device == 20 else 0)
                return mock.Mock(free=free)

            with mock.patch.object(
                converter.os, "stat", side_effect=stat_side_effect
            ), mock.patch.object(
                converter.shutil, "disk_usage", side_effect=short_disk_usage
            ), self.assertRaisesRegex(
                converter.AlphaConversionError, "insufficient free disk space"
            ):
                converter._check_peak_disk_capacity(
                    output,
                    report,
                    None,
                    info=info,
                    width=8,
                    height=6,
                    reserve_bytes=256,
                )

    def test_publication_disk_recheck_counts_only_remaining_target_allocations(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output_stage = root / "work" / "output.mov"
            intermediate_stage = root / "work" / "intermediate.mov"
            output = root / "target" / "output.mov"
            intermediate = root / "target" / "intermediate.mov"
            report = root / "target" / "output.report.json"
            output_stage.parent.mkdir()
            output.parent.mkdir()
            output_stage.write_bytes(b"o" * 101)
            intermediate_stage.write_bytes(b"i" * 203)
            payload = {"status": "converted", "quality": {"frames_checked": 1}}
            with mock.patch.object(
                converter.shutil, "disk_usage", return_value=mock.Mock(free=10**12)
            ):
                measured = converter._check_publication_disk_capacity(
                    output_stage,
                    output,
                    intermediate_stage,
                    intermediate,
                    report,
                    payload,
                    reserve_bytes=512,
                )
            self.assertEqual(measured["model"], "publication-remaining-v1")
            self.assertEqual(measured["volume_count"], 1)
            self.assertNotIn(str(root), json.dumps(measured))
            self.assertEqual(
                measured["volumes"][0]["components"],
                ["delivery-stage", "intermediate-stage", "report-stage"],
            )
            self.assertNotIn("conversion-temp", measured["volumes"][0]["components"])

            output.write_bytes(b"old-output")
            intermediate.write_bytes(b"old-intermediate")
            report.write_text('{"status":"old"}\n', encoding="utf-8")
            with mock.patch.object(
                converter.shutil, "disk_usage", return_value=mock.Mock(free=10**12)
            ):
                with_existing_targets = converter._check_publication_disk_capacity(
                    output_stage,
                    output,
                    intermediate_stage,
                    intermediate,
                    report,
                    payload,
                    reserve_bytes=512,
                )
            self.assertEqual(
                with_existing_targets["total_required_bytes"],
                measured["total_required_bytes"],
            )

            exact_required = measured["volumes"][0]["required_bytes"]
            with mock.patch.object(
                converter.shutil,
                "disk_usage",
                return_value=mock.Mock(free=exact_required),
            ):
                accepted = converter._check_publication_disk_capacity(
                    output_stage,
                    output,
                    intermediate_stage,
                    intermediate,
                    report,
                    payload,
                    reserve_bytes=512,
                )
            self.assertEqual(
                accepted["maximum_volume_required_bytes"], exact_required
            )

    def test_late_free_space_drop_blocks_publication_and_preserves_old_artifacts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            output = root / "idle.mov"
            intermediate = root / "idle.prores.mov"
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
                    "--min-free-disk-bytes",
                    "1",
                ]
            )
            source_info = alpha.VideoInfo(
                width=4,
                height=4,
                frame_count=1,
                fps=Fraction(24, 1),
                duration_seconds=1 / 24,
                codec_name="h264",
                pixel_format="yuv420p",
            )
            intermediate_info = alpha.VideoInfo(
                width=4,
                height=4,
                frame_count=1,
                fps=Fraction(24, 1),
                duration_seconds=1 / 24,
                codec_name="prores",
                pixel_format="yuva444p10le",
                codec_profile="4444",
            )

            def fake_probe(path, **_kwargs):
                return (
                    intermediate_info
                    if Path(path).name == "intermediate.prores4444.mov"
                    else source_info
                )

            def fake_stream(_source, stage, reference_alpha, **_kwargs):
                stage.write_bytes(b"new-intermediate")
                reference_alpha.write_bytes(b"\0" * 16)
                return {"frames_checked": 1, "quality_passed": True}

            def fake_avconvert(_source, stage, **_kwargs):
                stage.write_bytes(b"new-output")

            publication = mock.Mock()
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "require_tool", return_value="tool"
            ), mock.patch.object(
                converter,
                "_preflight_tool_capabilities",
                return_value={"toolchain": {}, "capabilities": {}},
            ), mock.patch.object(
                converter, "probe_video", side_effect=fake_probe
            ), mock.patch.object(
                converter,
                "verify_video_cadence",
                return_value={"quality_passed": True},
            ), mock.patch.object(
                converter,
                "_verify_source_background",
                return_value={"quality_passed": True},
            ), mock.patch.object(
                converter, "_stream_matte_to_prores", side_effect=fake_stream
            ), mock.patch.object(
                converter, "_run_avconvert", side_effect=fake_avconvert
            ), mock.patch.object(
                converter,
                "_verify_alpha_roundtrip",
                return_value={"performed": True, "unsafe": False, "frames_verified": 1},
            ), mock.patch.object(
                converter.shutil,
                "disk_usage",
                side_effect=[mock.Mock(free=10**12), mock.Mock(free=0)],
            ), mock.patch.object(
                converter, "_publish_transaction", publication
            ):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "insufficient free disk space"
                ):
                    converter.convert_video(args)
            publication.assert_not_called()
            self.assertEqual(output.read_bytes(), b"old-output")
            self.assertEqual(intermediate.read_bytes(), b"old-intermediate")
            self.assertEqual(
                report.read_text(encoding="utf-8"), '{"status":"old"}\n'
            )

    def test_insufficient_disk_fails_before_any_conversion_process_starts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            source.write_bytes(b"source")
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(root / "output.mov"),
                    "--min-free-disk-bytes",
                    "1000",
                ]
            )
            info = alpha.VideoInfo(
                width=4,
                height=4,
                frame_count=1,
                fps=Fraction(24, 1),
                duration_seconds=1 / 24,
                codec_name="h264",
                pixel_format="yuv420p",
            )
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "require_tool", side_effect=lambda _name, value: value
            ), mock.patch.object(
                converter, "probe_video", return_value=info
            ), mock.patch.object(
                converter.shutil, "disk_usage", return_value=mock.Mock(free=999)
            ), mock.patch.object(converter, "_start_process") as start_process:
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "insufficient free disk space"
                ):
                    converter.convert_video(args)
            start_process.assert_not_called()

    def test_source_size_budget_fails_before_hash_probe_or_decoder(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            source.write_bytes(b"x" * 11)
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(root / "output.mov"),
                    "--max-source-bytes",
                    "10",
                ]
            )
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "require_tool", side_effect=lambda name, _value: name
            ), mock.patch.object(
                converter,
                "_preflight_tool_capabilities",
                return_value={"toolchain": {}, "capabilities": {}},
            ), mock.patch.object(
                converter, "_sha256_source_file"
            ) as source_hash, mock.patch.object(
                converter, "probe_video"
            ) as probe, mock.patch.object(
                converter, "_start_process"
            ) as start_process:
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "size budget"
                ):
                    converter.convert_video(args)
            source_hash.assert_not_called()
            probe.assert_not_called()
            start_process.assert_not_called()

    def test_frame_budget_fails_before_deep_cadence_probe(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "small.mp4"
            source.write_bytes(b"small")
            args = converter.build_parser().parse_args(
                [
                    str(source),
                    str(root / "output.mov"),
                    "--max-source-frames",
                    "10",
                ]
            )
            info = alpha.VideoInfo(
                width=4,
                height=4,
                frame_count=1_000_000,
                fps=Fraction(24, 1),
                duration_seconds=1.0,
                codec_name="h264",
                pixel_format="yuv420p",
            )
            with mock.patch.object(
                converter, "require_image_dependencies"
            ), mock.patch.object(
                converter, "require_tool", side_effect=lambda name, _value: name
            ), mock.patch.object(
                converter,
                "_preflight_tool_capabilities",
                return_value={"toolchain": {}, "capabilities": {}},
            ), mock.patch.object(
                converter, "probe_video", return_value=info
            ), mock.patch.object(
                converter.shutil, "disk_usage", return_value=mock.Mock(free=10**12)
            ), mock.patch.object(
                converter, "verify_video_cadence"
            ) as cadence:
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "frame budget"
                ):
                    converter.convert_video(args)
            cadence.assert_not_called()

    def test_compact_cadence_probe_explicitly_enables_frame_sections(self):
        command = alpha.build_ffprobe_cadence_command(
            "source.mp4",
            stream_index=2,
            ffprobe="ffprobe",
        )

        self.assertIn("-show_frames", command)
        self.assertEqual(command[command.index("-select_streams") + 1], "2")
        packet_command = alpha.build_ffprobe_packet_cadence_command(
            "source.mp4",
            stream_index=2,
            ffprobe="ffprobe",
        )
        self.assertIn("-show_packets", packet_command)
        self.assertEqual(
            packet_command[packet_command.index("-show_entries") + 1],
            "packet=pts_time",
        )

    def test_compact_cadence_probe_ignores_ffprobe_side_data_columns(self):
        process = mock.Mock()
        process.stdout = io.BytesIO(
            b"0.000000,H.264 User Data Unregistered SEI message\n0.041667\n"
        )
        process.stdin = None
        process.stderr = None
        process.poll.return_value = 0
        process.wait.return_value = 0
        info = alpha.VideoInfo(
            width=4,
            height=4,
            frame_count=2,
            fps=Fraction(24, 1),
            duration_seconds=2 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )

        with mock.patch.object(alpha, "require_tool", return_value="ffprobe"):
            report = alpha.verify_video_cadence(
                "source.mp4",
                info,
                ffprobe="ffprobe",
                process_factory=lambda *_args, **_kwargs: process,
            )

            self.assertEqual(report["frames_checked"], 2)
            self.assertTrue(report["quality_passed"])

    def test_compact_cadence_count_error_identifies_stage_without_paths(self):
        info = alpha.VideoInfo(
            width=64,
            height=48,
            frame_count=2,
            fps=Fraction(24, 1),
            duration_seconds=2 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
            time_base="1/12288",
        )
        process = mock.Mock()
        process.stdout = io.BytesIO(b"0.000000\n")
        process.wait.return_value = 0
        process.poll.return_value = 0

        with mock.patch.object(alpha, "require_tool", return_value="ffprobe"):
            with self.assertRaisesRegex(
                alpha.ProbeError,
                r"source cadence exposed 1 timestamps for 2 decoded frames",
            ) as raised:
                alpha.verify_video_cadence(
                    Path("/private/source.mp4"),
                    info,
                    label="source",
                    process_factory=lambda *_args, **_kwargs: process,
                )
        self.assertNotIn("/private/source.mp4", str(raised.exception))

    def test_hevc_cadence_uses_strict_packet_pts_when_frames_expose_no_timestamps(self):
        info = alpha.VideoInfo(
            width=64,
            height=48,
            frame_count=3,
            fps=Fraction(24, 1),
            duration_seconds=3 / 24,
            codec_name="hevc",
            pixel_format="yuva420p",
            time_base="1/600",
        )
        frame_process = mock.Mock()
        frame_process.stdout = io.BytesIO(b"")
        frame_process.wait.return_value = 0
        frame_process.poll.return_value = 0
        packet_process = mock.Mock()
        # Packet PTS can be emitted in decode rather than presentation order.
        packet_process.stdout = io.BytesIO(b"0.083333\n0.000000\n0.041667\n")
        packet_process.wait.return_value = 0
        packet_process.poll.return_value = 0
        processes = iter((frame_process, packet_process))
        commands = []

        def factory(command, **_kwargs):
            commands.append(command)
            return next(processes)

        with mock.patch.object(alpha, "require_tool", return_value="ffprobe"):
            report = alpha.verify_video_cadence(
                "delivery.mov",
                info,
                label="HEVC delivery",
                allow_packet_fallback=True,
                process_factory=factory,
            )

        self.assertEqual(report["frames_checked"], 3)
        self.assertEqual(report["expected_frames"], 3)
        self.assertEqual(report["timestamp_source"], "packet_pts")
        self.assertIn("-show_frames", commands[0])
        self.assertIn("-show_packets", commands[1])

    def test_partial_frame_cadence_never_falls_back_to_packets(self):
        info = alpha.VideoInfo(
            width=64,
            height=48,
            frame_count=2,
            fps=Fraction(24, 1),
            duration_seconds=2 / 24,
            codec_name="hevc",
            pixel_format="yuva420p",
            time_base="1/600",
        )
        process = mock.Mock()
        process.stdout = io.BytesIO(b"0.000000\n")
        process.wait.return_value = 0
        process.poll.return_value = 0
        calls = []

        def factory(command, **_kwargs):
            calls.append(command)
            return process

        with mock.patch.object(alpha, "require_tool", return_value="ffprobe"):
            with self.assertRaisesRegex(
                alpha.ProbeError,
                r"HEVC delivery cadence exposed 1 timestamps for 2 decoded frames",
            ):
                alpha.verify_video_cadence(
                    "delivery.mov",
                    info,
                    label="HEVC delivery",
                    allow_packet_fallback=True,
                    process_factory=factory,
                )
        self.assertEqual(len(calls), 1)

    def test_compact_cadence_probe_terminates_when_output_cap_is_exceeded(self):
        process = mock.Mock()
        process.stdout = io.BytesIO(b"0.000000\n0.041667\n")
        process.stdin = None
        process.stderr = None
        process.poll.return_value = 0
        process.wait.return_value = 0
        info = alpha.VideoInfo(
            width=4,
            height=4,
            frame_count=2,
            fps=Fraction(24, 1),
            duration_seconds=2 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        with mock.patch.object(alpha, "require_tool", return_value="ffprobe"):
            with self.assertRaisesRegex(alpha.ProbeError, "output exceeds"):
                alpha.verify_video_cadence(
                    "source.mp4",
                    info,
                    ffprobe="ffprobe",
                    max_output_bytes=8,
                    process_factory=lambda *_args, **_kwargs: process,
                )
        self.assertTrue(process.stdout.closed)

    def test_source_background_reference_io_failure_is_path_private(self):
        info = alpha.VideoInfo(
            width=4,
            height=4,
            frame_count=1,
            fps=Fraction(24, 1),
            duration_seconds=1 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        decoder = mock.Mock()
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(
            converter, "_start_process", return_value=decoder
        ), mock.patch.object(converter, "close_process"):
            private_path = Path(temp) / "missing" / "background.rgb"
            with self.assertRaisesRegex(
                converter.AlphaConversionError,
                "unable to write source background reference",
            ) as raised:
                converter._verify_source_background(
                    Path(temp) / "source.mp4",
                    background_reference=private_path,
                    info=info,
                    ffmpeg="ffmpeg",
                    timeout_seconds=1,
                )
            self.assertNotIn(temp, str(raised.exception))

    def test_source_background_reference_write_and_fsync_failures_are_sanitized(self):
        info = alpha.VideoInfo(
            width=2,
            height=2,
            frame_count=1,
            fps=Fraction(24, 1),
            duration_seconds=1 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        evidence = {
            "background_rgb": [0, 255, 0],
            "green_source_ratio": 1.0,
            "green_source_border_ratio": 1.0,
            "green_source_row_coverage": 1.0,
            "green_source_column_coverage": 1.0,
        }
        for stage in ("write", "fsync"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                reference = root / "background.rgb"
                decoder = mock.Mock()
                patches = [
                    mock.patch.object(converter, "_start_process", return_value=decoder),
                    mock.patch.object(converter, "close_process"),
                    mock.patch.object(converter, "read_raw_frames", return_value=iter([object()])),
                    mock.patch.object(converter, "assess_green_background", return_value=evidence),
                ]
                if stage == "write":
                    handle = mock.MagicMock()
                    handle.__enter__.return_value = handle
                    handle.write.side_effect = OSError("private write failure")
                    patches.append(mock.patch.object(Path, "open", return_value=handle))
                else:
                    patches.append(mock.patch.object(converter.os, "fsync", side_effect=OSError("private fsync failure")))
                for active in patches:
                    active.start()
                try:
                    with self.assertRaisesRegex(
                        converter.AlphaConversionError,
                        "unable to write source background reference",
                    ) as raised:
                        converter._verify_source_background(
                            root / "source.mp4",
                            background_reference=reference,
                            info=info,
                            ffmpeg="ffmpeg",
                            timeout_seconds=1,
                        )
                    self.assertNotIn(temp, str(raised.exception))
                finally:
                    for active in reversed(patches):
                        active.stop()

    def test_source_background_preflight_emits_per_frame_progress(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        frame = np.zeros((4, 4, 3), dtype=np.uint8)
        frame[:, :] = (0, 255, 0)
        info = alpha.VideoInfo(
            width=4,
            height=4,
            frame_count=3,
            fps=Fraction(24, 1),
            duration_seconds=3 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        progress = mock.Mock()
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(
            converter, "_start_process", return_value=mock.Mock()
        ), mock.patch.object(
            converter, "read_raw_frames", return_value=iter([frame, frame, frame])
        ), mock.patch.object(converter, "close_process"):
            report = converter._verify_source_background(
                Path(temp) / "source.mp4",
                background_reference=Path(temp) / "background.rgb",
                info=info,
                ffmpeg="ffmpeg",
                timeout_seconds=10,
                progress=progress,
            )
        self.assertEqual(report["frames_checked"], 3)
        self.assertEqual(report["strict_background_attestation_frames"], 3)
        self.assertEqual(report["temporal_occlusion_frames"], 0)
        self.assertEqual(progress.emit.call_count, 3)
        self.assertEqual(progress.emit.call_args.kwargs["frame_completed"], 3)

    def test_source_background_preflight_reuses_attested_green_during_occlusion(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        green = np.zeros((100, 100, 3), dtype=np.uint8)
        green[:, :] = (0, 255, 0)
        occluded = np.zeros((100, 100, 3), dtype=np.uint8)
        occluded[:, :] = (40, 90, 150)
        occluded[:21, :21] = (0, 255, 0)
        info = alpha.VideoInfo(
            width=100,
            height=100,
            frame_count=4,
            fps=Fraction(24, 1),
            duration_seconds=4 / 24,
            codec_name="h264",
            pixel_format="yuv420p",
        )
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(
            converter, "_start_process", return_value=mock.Mock()
        ), mock.patch.object(
            converter,
            "read_raw_frames",
            return_value=iter([green, green, green, occluded]),
        ), mock.patch.object(converter, "close_process"):
            report = converter._verify_source_background(
                Path(temp) / "source.mp4",
                background_reference=Path(temp) / "background.rgb",
                info=info,
                ffmpeg="ffmpeg",
                timeout_seconds=10,
            )

        self.assertEqual(report["strict_background_attestation_frames"], 3)
        self.assertEqual(report["temporal_occlusion_frames"], 1)

    def test_roundtrip_verification_threads_nondefault_timeout_everywhere(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        np = alpha.np
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            delivery = root / "delivery.mov"
            reference_video = root / "reference.mov"
            reference_alpha = root / "alpha.raw"
            delivery.write_bytes(b"delivery")
            reference_video.write_bytes(b"reference")
            reference_alpha.write_bytes(b"\0")
            expected = alpha.VideoInfo(
                width=1,
                height=1,
                frame_count=1,
                fps=Fraction(24, 1),
                duration_seconds=1 / 24,
                codec_name="",
                pixel_format="",
            )
            delivery_info = alpha.VideoInfo(
                **{**vars(expected), "codec_name": "hevc", "pixel_format": "yuv420p"}
            )
            roundtrip_info = alpha.VideoInfo(
                **{
                    **vars(expected),
                    "codec_name": "prores",
                    "pixel_format": "yuva444p10le",
                    "codec_profile": "4444",
                    "bit_depth": 10,
                }
            )
            rgba = np.zeros((1, 1, 4), dtype=np.uint8)
            process_pair = (mock.Mock(), mock.Mock())

            def fake_avconvert(_source, output, **_kwargs):
                output.write_bytes(b"roundtrip")

            with mock.patch.object(
                converter, "probe_video", side_effect=[delivery_info, roundtrip_info]
            ) as probe, mock.patch.object(
                converter, "_run_avconvert", side_effect=fake_avconvert
            ) as avconvert, mock.patch.object(
                converter, "_start_rgba_decoder_pair", return_value=process_pair
            ), mock.patch.object(
                converter,
                "verify_video_cadence",
                return_value={"quality_passed": True},
            ) as cadence, mock.patch.object(
                converter,
                "read_raw_frames",
                side_effect=[iter([rgba.copy()]), iter([rgba.copy()])],
            ) as raw_frames, mock.patch.object(converter, "close_process"):
                report = converter._verify_alpha_roundtrip(
                    delivery,
                    reference_alpha,
                    reference_video=reference_video,
                    expected=expected,
                    avconvert="avconvert",
                    ffprobe="ffprobe",
                    ffmpeg="ffmpeg",
                    max_border_alpha=16,
                    max_green_edge_ratio=0.05,
                    max_magenta_edge_ratio=0.05,
                    source_edge_alpha_floor=64,
                    max_mean_abs_error=8,
                    max_p95_abs_error=24,
                    max_abs_error=64,
                    loss_threshold=20,
                    require_foreground=False,
                    timeout_seconds=7,
                )
            self.assertTrue(report["performed"])
            self.assertTrue(all(call.kwargs["timeout_seconds"] == 7 for call in probe.call_args_list))
            self.assertEqual(avconvert.call_args.kwargs["timeout_seconds"], 7)
            self.assertTrue(
                all(call.kwargs["timeout_seconds"] == 7 for call in cadence.call_args_list)
            )
            self.assertTrue(
                all(call.kwargs["timeout_seconds"] == 7 for call in raw_frames.call_args_list)
            )

    def test_missing_tool_capability_fails_before_hash_or_decoder_start(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.mp4"
            source.write_bytes(b"source")
            args = converter.build_parser().parse_args(
                [str(source), str(root / "output.mov")]
            )
            complete = {
                ("ffmpeg", ("-hide_banner", "-encoders")): " VFS... prores_ks encoder\n",
                ("ffmpeg", ("-hide_banner", "-filters")): (
                    " .. scale V->V\n .. crop V->V\n .. pad V->V\n"
                ),
                ("ffmpeg", ("-hide_banner", "-h", "full")): (
                    " -fps_mode[:stream_specifier] set framerate mode\n"
                ),
                ("avconvert", ("--help",)): (
                    f"{converter.DEFAULT_PRESET}\n{converter.ROUNDTRIP_PRESET}\n"
                ),
                ("ffmpeg", ("-version",)): "ffmpeg version test\n",
                ("ffprobe", ("-version",)): "ffprobe version test\n",
                ("/usr/bin/sw_vers", ("-buildVersion",)): "23G93\n",
            }
            cases = (
                ("encoder", ("ffmpeg", ("-hide_banner", "-encoders")), "", "prores_ks"),
                ("scale", ("ffmpeg", ("-hide_banner", "-filters")), " .. crop V->V\n .. pad V->V\n", "scale filter"),
                ("crop", ("ffmpeg", ("-hide_banner", "-filters")), " .. scale V->V\n .. pad V->V\n", "crop filter"),
                ("pad", ("ffmpeg", ("-hide_banner", "-filters")), " .. scale V->V\n .. crop V->V\n", "pad filter"),
                ("frame sync", ("ffmpeg", ("-hide_banner", "-h", "full")), "", "frame synchronization"),
                ("delivery preset", ("avconvert", ("--help",)), converter.ROUNDTRIP_PRESET, converter.DEFAULT_PRESET),
                ("roundtrip preset", ("avconvert", ("--help",)), converter.DEFAULT_PRESET, converter.ROUNDTRIP_PRESET),
            )
            for label, missing_key, replacement, message in cases:
                outputs = dict(complete)
                outputs[missing_key] = replacement

                def fake_output(executable, arguments, **_kwargs):
                    return outputs[(executable, arguments)]

                with self.subTest(label=label), mock.patch.object(
                    converter, "require_image_dependencies"
                ), mock.patch.object(
                    converter, "require_tool", side_effect=lambda name, _value: name
                ), mock.patch.object(
                    converter, "_bounded_tool_output", side_effect=fake_output
                ), mock.patch.object(
                    converter, "_sha256_source_file"
                ) as source_hash, mock.patch.object(
                    converter, "_start_process"
                ) as start_process:
                    with self.assertRaisesRegex(converter.AlphaConversionError, message):
                        converter.convert_video(args)
                source_hash.assert_not_called()
                start_process.assert_not_called()

    def test_tool_capability_preflight_reuses_cached_help_for_report_versions(self):
        outputs = {
            ("ffmpeg", ("-hide_banner", "-encoders")): " VFS... prores_ks encoder\n",
            ("ffmpeg", ("-hide_banner", "-filters")): " .. scale V->V\n .. crop V->V\n .. pad V->V\n",
            ("ffmpeg", ("-hide_banner", "-h", "full")): (
                " -fps_mode[:stream_specifier] set framerate mode\n"
            ),
            ("avconvert", ("--help",)): f"avconvert help\n{converter.DEFAULT_PRESET}\n{converter.ROUNDTRIP_PRESET}\n",
            ("ffmpeg", ("-version",)): "ffmpeg version test\n",
            ("ffprobe", ("-version",)): "ffprobe version test\n",
            ("/usr/bin/sw_vers", ("-buildVersion",)): "23G93\n",
        }

        with mock.patch.object(
            converter, "_bounded_tool_output", side_effect=lambda executable, arguments, **_kwargs: outputs[(executable, arguments)]
        ) as bounded:
            result = converter._preflight_tool_capabilities(
                ffmpeg="ffmpeg", ffprobe="ffprobe", avconvert="avconvert"
            )
        self.assertTrue(result["capabilities"]["passed"])
        av_help_calls = [
            call for call in bounded.call_args_list
            if call.args[:2] == ("avconvert", ("--help",))
        ]
        self.assertEqual(len(av_help_calls), 1)

    def test_toolchain_fingerprints_are_deterministic_and_path_free(self):
        with tempfile.NamedTemporaryFile() as avconvert_file:
            avconvert_path = avconvert_file.name

            def fake_output(executable, arguments, **_kwargs):
                if arguments == ("-hide_banner", "-encoders"):
                    return " VFS... prores_ks encoder\n"
                if arguments == ("-hide_banner", "-filters"):
                    return " .. scale V->V\n .. crop V->V\n .. pad V->V\n"
                if arguments == ("-hide_banner", "-h", "full"):
                    return " -fps_mode[:stream_specifier] set framerate mode\n"
                if arguments == ("--help",):
                    return f"help\n{converter.DEFAULT_PRESET}\n{converter.ROUNDTRIP_PRESET}\n"
                if executable == "/usr/bin/sw_vers":
                    return "23G93\n"
                return f"{Path(executable).name} version test\n"

            def fake_hash(path):
                if Path(path) == Path(avconvert_path):
                    return "a" * 64
                if Path(path) == Path(alpha.__file__):
                    return "d" * 64
                return "c" * 64

            with mock.patch.object(
                converter, "_bounded_tool_output", side_effect=fake_output
            ), mock.patch.object(converter, "_sha256_file", side_effect=fake_hash):
                first = converter._preflight_tool_capabilities(
                    ffmpeg="ffmpeg",
                    ffprobe="ffprobe",
                    avconvert=avconvert_path,
                )
                second = converter._preflight_tool_capabilities(
                    ffmpeg="ffmpeg",
                    ffprobe="ffprobe",
                    avconvert=avconvert_path,
                )
            self.assertEqual(first["toolchain"], second["toolchain"])
            combined = hashlib.sha256(
                (("c" * 64) + ":" + ("d" * 64)).encode("ascii")
            ).hexdigest()
            self.assertEqual(
                first["toolchain"]["converter_version"], "sha256-" + combined
            )
            self.assertEqual(first["toolchain"]["avconvert_version"], "sha256-" + "a" * 64)
            self.assertEqual(first["toolchain"]["macos_build"], "23G93")
            self.assertNotIn(tempfile.gettempdir(), json.dumps(first["toolchain"]))

    def test_tool_capability_preflight_falls_back_to_legacy_vsync(self):
        outputs = {
            ("ffmpeg", ("-hide_banner", "-encoders")): " VFS... prores_ks encoder\n",
            ("ffmpeg", ("-hide_banner", "-filters")): (
                " .. scale V->V\n .. crop V->V\n .. pad V->V\n"
            ),
            ("ffmpeg", ("-hide_banner", "-h", "full")): (
                " -vsync parameter set video sync method globally\n"
            ),
            ("avconvert", ("--help",)): (
                f"{converter.DEFAULT_PRESET}\n{converter.ROUNDTRIP_PRESET}\n"
            ),
            ("ffmpeg", ("-version",)): "ffmpeg version 5.0\n",
            ("ffprobe", ("-version",)): "ffprobe version 5.0\n",
            ("/usr/bin/sw_vers", ("-buildVersion",)): "23G93\n",
        }
        with mock.patch.object(
            converter,
            "_bounded_tool_output",
            side_effect=lambda executable, arguments, **_kwargs: outputs[
                (executable, arguments)
            ],
        ):
            result = converter._preflight_tool_capabilities(
                ffmpeg="ffmpeg", ffprobe="ffprobe", avconvert="avconvert"
            )
        self.assertEqual(result["capabilities"]["ffmpeg_frame_sync"], "vsync")

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
            ), mock.patch.object(
                converter,
                "_preflight_tool_capabilities",
                return_value={"toolchain": {}, "capabilities": {}},
            ), mock.patch.object(
                converter, "verify_video_cadence", return_value={"quality_passed": True}
            ), mock.patch.object(
                converter,
                "_verify_source_background",
                return_value={"quality_passed": True},
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
                if path.name.startswith("backup-"):
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
                converter._assert_source_unchanged(
                    source, digest, max_source_bytes=1024
                )

    def test_source_digest_hashes_normal_nonempty_mp4(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source.mp4"
            payload = b"normal-mp4-source"
            source.write_bytes(payload)

            self.assertEqual(
                converter._sha256_source_file(source),
                hashlib.sha256(payload).hexdigest(),
            )

    def test_source_digest_rejects_growth_during_capped_fd_hash(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source.mp4"
            source.write_bytes(b"bounded-source")
            original_read = os.read
            appended = False

            def read_then_append(descriptor, count):
                nonlocal appended
                chunk = original_read(descriptor, count)
                if chunk and not appended:
                    appended = True
                    with source.open("ab") as handle:
                        handle.write(b"growth")
                return chunk

            with mock.patch.object(converter.os, "read", side_effect=read_then_append):
                with self.assertRaisesRegex(
                    converter.AlphaConversionError, "changed during hashing"
                ):
                    converter._sha256_source_file(
                        source, max_source_bytes=len(b"bounded-source")
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
            ), mock.patch.object(
                converter,
                "_preflight_tool_capabilities",
                return_value={"toolchain": {}, "capabilities": {}},
            ), mock.patch.object(
                converter, "verify_video_cadence", return_value={"quality_passed": True}
            ), mock.patch.object(
                converter,
                "_verify_source_background",
                return_value={"quality_passed": True},
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
                        "pix_fmt": "yuv420p",
                        "bits_per_raw_sample": "8",
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
                        "pix_fmt": "yuv420p",
                        "bits_per_raw_sample": "8",
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
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
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

    def test_probe_records_selected_playable_stream_index_for_decode(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            playable = {
                "index": 7,
                "codec_type": "video",
                "codec_name": "h264",
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "2",
                "duration": "0.083333",
            }
            cover = dict(playable, index=0, disposition={"attached_pic": 1})
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps({"streams": [cover, playable]}), ""
            )

            info = alpha.probe_video(
                source.name,
                ffprobe="/opt/homebrew/bin/ffprobe",
                runner=lambda *args, **kwargs: result,
            )
            command = alpha.build_ffmpeg_decode_command(
                source.name,
                width=16,
                height=16,
                stream_index=info.stream_index,
            )

            self.assertEqual(info.stream_index, 7)
            self.assertEqual(command[command.index("-map") + 1], "0:7")

    def test_probe_rejects_hdr_and_interlaced_sources_before_decode(self):
        base_stream = {
            "index": 0,
            "codec_type": "video",
            "codec_name": "hevc",
            "width": 16,
            "height": 16,
            "avg_frame_rate": "24/1",
            "r_frame_rate": "24/1",
            "nb_read_frames": "2",
            "duration": "0.083333",
        }
        for metadata, message in (
            ({"color_transfer": "smpte2084", "color_primaries": "bt2020"}, "HDR"),
            ({"field_order": "tt"}, "interlaced"),
        ):
            with self.subTest(metadata=metadata), tempfile.NamedTemporaryFile(
                suffix=".mp4"
            ) as source:
                stream = dict(base_stream, **metadata)
                result = subprocess.CompletedProcess(
                    ["ffprobe"], 0, json.dumps({"streams": [stream]}), ""
                )
                with self.assertRaisesRegex(alpha.ProbeError, message):
                    alpha.probe_video(
                        source.name,
                        ffprobe="/opt/homebrew/bin/ffprobe",
                        runner=lambda *args, **kwargs: result,
                    )

    def test_probe_rejects_ten_bit_sdr_source_before_rgb24_decode(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 0,
                "codec_type": "video",
                "codec_name": "hevc",
                "pix_fmt": "yuv420p10le",
                "bits_per_raw_sample": "10",
                "color_primaries": "bt709",
                "color_transfer": "bt709",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "2",
                "duration": "0.083333",
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps({"streams": [stream]}), ""
            )
            with self.assertRaisesRegex(alpha.ProbeError, "more than 8 bits"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=lambda *args, **kwargs: result,
                )

    def test_pixel_format_bit_depth_fallback_covers_planar_and_packed_formats(self):
        for pixel_format, expected in (
            ("gray10le", 10),
            ("rgb48le", 16),
            ("rgba64le", 16),
            ("xyz12le", 12),
            ("x2rgb10le", 10),
            ("nv20le", 10),
            ("gray", 8),
            ("rgb24", 8),
            ("rgba", 8),
            ("unknown-private-format", None),
        ):
            with self.subTest(pixel_format=pixel_format):
                self.assertEqual(
                    alpha._pixel_format_bit_depth(pixel_format), expected
                )

    def test_probe_rejects_unknown_bit_depth_instead_of_assuming_eight_bit(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 0,
                "codec_type": "video",
                "codec_name": "private",
                "pix_fmt": "unknown-private-format",
                "bits_per_raw_sample": "0",
                "color_primaries": "bt709",
                "color_transfer": "bt709",
                "color_space": "bt709",
                "color_range": "tv",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "2",
                "duration": "0.083333",
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps({"streams": [stream]}), ""
            )
            with self.assertRaisesRegex(alpha.ProbeError, "could not be verified"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=lambda *args, **kwargs: result,
                )

    def test_probe_accepts_bt709_sdr_color_metadata(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 0,
                "codec_type": "video",
                "codec_name": "h264",
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
                "color_primaries": "bt709",
                "color_transfer": "bt709",
                "color_space": "bt709",
                "color_range": "tv",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "2",
                "duration": "0.083333",
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps({"streams": [stream]}), ""
            )
            info = alpha.probe_video(
                source.name,
                ffprobe="/opt/homebrew/bin/ffprobe",
                runner=lambda *args, **kwargs: result,
            )
            self.assertEqual(info.color_primaries, "bt709")
            self.assertEqual(info.bit_depth, 8)

    def test_probe_rejects_display_p3_wide_gamut_metadata(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 0,
                "codec_type": "video",
                "codec_name": "h264",
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
                "color_primaries": "smpte432",
                "color_transfer": "iec61966-2-1",
                "color_space": "bt709",
                "color_range": "pc",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "2",
                "duration": "0.083333",
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps({"streams": [stream]}), ""
            )
            with self.assertRaisesRegex(alpha.ProbeError, "wide-gamut"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=lambda *args, **kwargs: result,
                )

    def test_probe_rejects_nonuniform_pts_even_when_aggregate_rates_match(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 0,
                "codec_type": "video",
                "codec_name": "h264",
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "4",
                "duration": "0.166667",
            }
            payload = {
                "streams": [stream],
                "frames": [
                    {
                        "stream_index": 0,
                        "media_type": "video",
                        "best_effort_timestamp_time": value,
                    }
                    for value in ("0.000000", "0.030000", "0.083333", "0.113333")
                ],
            }
            result = subprocess.CompletedProcess(
                ["ffprobe"], 0, json.dumps(payload), ""
            )
            with self.assertRaisesRegex(alpha.ProbeError, "not uniformly spaced"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=lambda *args, **kwargs: result,
                    validate_timestamps=True,
                )

    def test_probe_cadence_ignores_interleaved_audio_frames(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 1,
                "codec_type": "video",
                "codec_name": "h264",
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "3",
                "duration": "0.125",
            }
            payload = {
                "streams": [stream, {"index": 0, "codec_type": "audio", "codec_name": "aac"}],
                "frames": [
                    {"stream_index": 0, "media_type": "audio", "best_effort_timestamp_time": "0.000"},
                    {"stream_index": 1, "media_type": "video", "best_effort_timestamp_time": "0.000000"},
                    {"stream_index": 0, "media_type": "audio", "best_effort_timestamp_time": "0.021"},
                    {"stream_index": 1, "media_type": "video", "best_effort_timestamp_time": "0.041667"},
                    {"stream_index": 1, "media_type": "video", "best_effort_timestamp_time": "0.083333"},
                ],
            }
            result = subprocess.CompletedProcess(["ffprobe"], 0, json.dumps(payload), "")
            info = alpha.probe_video(
                source.name,
                ffprobe="/opt/homebrew/bin/ffprobe",
                runner=lambda *args, **kwargs: result,
                validate_timestamps=True,
            )
            self.assertEqual(info.frame_count, 3)

    def test_probe_accepts_cfr_timestamps_quantized_to_container_time_base(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 0,
                "codec_type": "video",
                "codec_name": "h264",
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
                "width": 16,
                "height": 16,
                "time_base": "1/1000",
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "4",
                "duration": "0.166667",
            }
            payload = {
                "streams": [stream],
                "frames": [
                    {
                        "stream_index": 0,
                        "media_type": "video",
                        "best_effort_timestamp_time": value,
                    }
                    for value in ("0.000", "0.042", "0.083", "0.125")
                ],
            }
            result = subprocess.CompletedProcess(["ffprobe"], 0, json.dumps(payload), "")
            info = alpha.probe_video(
                source.name,
                ffprobe="/opt/homebrew/bin/ffprobe",
                runner=lambda *args, **kwargs: result,
                validate_timestamps=True,
            )
            self.assertEqual(info.time_base, "1/1000")

    def test_probe_cadence_rejects_missing_selected_video_timestamp(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            stream = {
                "index": 0,
                "codec_type": "video",
                "codec_name": "h264",
                "pix_fmt": "yuv420p",
                "bits_per_raw_sample": "8",
                "width": 16,
                "height": 16,
                "avg_frame_rate": "24/1",
                "r_frame_rate": "24/1",
                "nb_read_frames": "2",
                "duration": "0.083333",
            }
            payload = {
                "streams": [stream],
                "frames": [
                    {"stream_index": 0, "media_type": "video", "best_effort_timestamp_time": "0.000000"},
                    {"stream_index": 0, "media_type": "video", "best_effort_timestamp_time": "N/A"},
                ],
            }
            result = subprocess.CompletedProcess(["ffprobe"], 0, json.dumps(payload), "")
            with self.assertRaisesRegex(alpha.ProbeError, "timestamp metadata is missing"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=lambda *args, **kwargs: result,
                    validate_timestamps=True,
                )

    def test_probe_runner_has_a_bounded_deadline(self):
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            runner = mock.Mock(side_effect=subprocess.TimeoutExpired("ffprobe", 1))
            with self.assertRaisesRegex(alpha.ProbeError, "timed out"):
                alpha.probe_video(
                    source.name,
                    ffprobe="/opt/homebrew/bin/ffprobe",
                    runner=runner,
                    timeout_seconds=1,
                )
            self.assertEqual(runner.call_args.kwargs["timeout"], 1)

    def test_read_raw_frames_accumulates_short_pipe_reads(self):
        np = alpha.np
        if np is None:
            self.skipTest("NumPy is required")

        class ShortReader:
            def __init__(self, payload):
                self.payload = bytearray(payload)

            def read(self, count):
                if not self.payload:
                    return b""
                take = min(2, count, len(self.payload))
                chunk = bytes(self.payload[:take])
                del self.payload[:take]
                return chunk

        process = mock.Mock()
        process.stdout = ShortReader(bytes(range(12)))
        process.wait.return_value = 0
        frames = list(
            alpha.read_raw_frames(
                process, width=2, height=2, expected_frames=1, channels=3
            )
        )
        self.assertEqual(frames[0].tobytes(), bytes(range(12)))

    def test_read_raw_frames_times_out_when_partial_frame_stalls(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")
        read_descriptor, write_descriptor = os.pipe()
        os.write(write_descriptor, b"\x00\x01")
        process = mock.Mock()
        process.stdout = os.fdopen(read_descriptor, "rb", buffering=0)
        process.stdin = None
        process.stderr = None
        process.poll.return_value = 0
        try:
            with self.assertRaisesRegex(alpha.AlphaConversionError, "timed out"):
                list(
                    alpha.read_raw_frames(
                        process,
                        width=2,
                        height=2,
                        expected_frames=1,
                        channels=3,
                        timeout_seconds=0.05,
                    )
                )
        finally:
            os.close(write_descriptor)

    def test_read_raw_frames_wait_uses_remaining_absolute_deadline(self):
        if alpha.np is None:
            self.skipTest("NumPy is required")

        class Reader:
            def __init__(self):
                self.chunks = [b"\0\0\0", b""]

            def read(self, _count):
                return self.chunks.pop(0)

        process = mock.Mock()
        process.stdout = Reader()
        process.wait.return_value = 0
        with mock.patch.object(
            alpha.time, "monotonic", side_effect=[0.0, 0.1, 0.2, 0.7]
        ):
            list(
                alpha.read_raw_frames(
                    process,
                    width=1,
                    height=1,
                    expected_frames=1,
                    channels=3,
                    timeout_seconds=1.0,
                )
            )
        self.assertAlmostEqual(process.wait.call_args.kwargs["timeout"], 0.3)

    def test_bounded_capture_inherits_converter_group_and_stops_noisy_output(self):
        group_result = alpha._run_bounded_capture(
            [sys.executable, "-c", "import os; print(os.getpgrp())"],
            timeout_seconds=2,
            stdout_limit=1024,
            stderr_limit=1024,
            overflow_message="overflow",
            timeout_message="timeout",
        )
        self.assertEqual(int(group_result.stdout.strip()), os.getpgrp())

        started = time.monotonic()
        with self.assertRaisesRegex(alpha.ProbeError, "overflow"):
            alpha._run_bounded_capture(
                [sys.executable, "-c", "import os; os.write(1, b'x' * 2000000)"],
                timeout_seconds=2,
                stdout_limit=1024 * 1024,
                stderr_limit=1024,
                overflow_message="overflow",
                timeout_message="timeout",
            )
        self.assertLess(time.monotonic() - started, 1.0)

    def test_close_process_reaps_after_kill(self):
        process = mock.Mock()
        process.stdin = None
        process.stdout = None
        process.stderr = None
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("ffmpeg", 2), 0]

        alpha.close_process(process)

        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)
        self.assertEqual(process.wait.call_args_list[-1].kwargs["timeout"], 2)

    def test_encoder_write_deadline_bounds_a_full_pipe(self):
        read_descriptor, write_descriptor = os.pipe()
        os.set_blocking(write_descriptor, False)
        try:
            while True:
                os.write(write_descriptor, b"x" * 65536)
        except BlockingIOError:
            pass
        stream = os.fdopen(write_descriptor, "wb", buffering=0)
        started = time.monotonic()
        try:
            with self.assertRaisesRegex(
                converter.AlphaConversionError, "encoding timed out"
            ):
                converter._write_all_with_deadline(
                    stream,
                    b"frame",
                    deadline=time.monotonic() + 0.05,
                )
        finally:
            stream.close()
            os.close(read_descriptor)
        self.assertLess(time.monotonic() - started, 0.5)

    def test_encoder_write_rejects_non_fd_stream_instead_of_bypassing_deadline(self):
        stream = mock.Mock()
        stream.fileno.side_effect = OSError("no descriptor")
        with self.assertRaisesRegex(
            converter.AlphaConversionError, "does not support bounded writes"
        ):
            converter._write_all_with_deadline(
                stream, b"frame", deadline=time.monotonic() + 1
            )
        stream.write.assert_not_called()

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

    def test_non_green_background_is_rejected_before_false_opaque_success(self):
        np = alpha.np
        frame = np.zeros((40, 48, 3), dtype=np.uint8)
        frame[:, :] = (32, 32, 180)
        frame[12:28, 15:33] = (220, 184, 170)

        with self.assertRaisesRegex(alpha.FrameQualityError, "green-screen background"):
            alpha.matte_frame(frame)

    def test_green_background_suitability_is_reported(self):
        frame, _ = self._synthetic_frame()
        diagnostics = {}
        alpha.matte_frame(frame, diagnostics=diagnostics)
        self.assertGreaterEqual(diagnostics["green_background_border_ratio"], 0.5)

    def test_fit_suitability_excludes_synthetic_green_padding(self):
        np = alpha.np
        canvas = np.zeros((40, 40, 3), dtype=np.uint8)
        canvas[:, :] = (0, 255, 0)
        bounds = (11, 4, 29, 36)  # 9:16 source fitted inside a square canvas.
        left, top, right, bottom = bounds
        canvas[top:bottom, left:right] = (80, 80, 80)
        canvas[14:26, 14:26] = (220, 184, 170)

        with self.assertRaisesRegex(alpha.FrameQualityError, "green-screen background"):
            alpha.matte_frame(canvas, suitability_bounds=bounds)

    def test_fit_suitability_accepts_real_green_source_inside_padding(self):
        np = alpha.np
        canvas = np.zeros((40, 40, 3), dtype=np.uint8)
        canvas[:, :] = (0, 255, 0)
        bounds = (11, 4, 29, 36)
        canvas[14:26, 14:26] = (220, 184, 170)

        rgba = alpha.matte_frame(canvas, suitability_bounds=bounds)
        self.assertGreater(int(rgba[:, :, 3].max()), 0)

    def test_source_attestation_rejects_green_subject_on_non_green_background(self):
        np = alpha.np
        frame = np.zeros((40, 40, 3), dtype=np.uint8)
        frame[:, :] = (90, 90, 90)
        frame[10:30, 10:30] = (0, 255, 0)
        with self.assertRaisesRegex(alpha.FrameQualityError, "green-screen background"):
            alpha.assess_green_background(frame)

    def test_source_attestation_rejects_top_touching_green_object_on_gray(self):
        np = alpha.np
        frame = np.zeros((100, 100, 3), dtype=np.uint8)
        frame[:, :] = (96, 96, 96)
        frame[:20, 35:65] = (0, 255, 0)
        with self.assertRaisesRegex(
            alpha.FrameQualityError, "green-screen background"
        ):
            alpha.assess_green_background(frame)

    def test_source_attestation_rejects_three_pixel_green_cross_on_gray(self):
        np = alpha.np
        frame = np.zeros((100, 100, 3), dtype=np.uint8)
        frame[:, :] = (96, 96, 96)
        frame[:, 49:52] = (0, 255, 0)
        frame[49:52, :] = (0, 255, 0)
        with self.assertRaisesRegex(
            alpha.FrameQualityError, "green-screen background"
        ):
            alpha.assess_green_background(frame)

    def test_temporal_source_attestation_accepts_matching_sparse_green_pocket(self):
        np = alpha.np
        frame = np.zeros((100, 100, 3), dtype=np.uint8)
        frame[:, :] = (40, 90, 150)
        frame[:21, :21] = (0, 255, 0)

        evidence = alpha.assess_temporally_occluded_green_background(
            frame,
            trusted_background_rgb=(0, 255, 0),
        )

        self.assertTrue(evidence["used_temporal_occlusion_policy"])
        self.assertEqual(evidence["background_rgb"], [0, 255, 0])

    def test_temporal_source_attestation_rejects_mismatched_green_pocket(self):
        np = alpha.np
        frame = np.zeros((100, 100, 3), dtype=np.uint8)
        frame[:, :] = (40, 90, 150)
        frame[:21, :21] = (30, 200, 0)

        with self.assertRaisesRegex(
            alpha.FrameQualityError, "previously attested background"
        ):
            alpha.assess_temporally_occluded_green_background(
                frame,
                trusted_background_rgb=(0, 255, 0),
            )

    def test_relaxed_edge_contact_uses_attested_source_green_not_cropped_perimeter(self):
        np = alpha.np
        source = np.zeros((40, 40, 3), dtype=np.uint8)
        source[:, :] = (0, 255, 0)
        # Subject/effect covers most of the perimeter but leaves small,
        # connected green source-space evidence and a green interior pocket.
        source[:8, :] = (210, 180, 160)
        source[-8:, :] = (210, 180, 160)
        source[:, :8] = (210, 180, 160)
        source[:, -8:] = (210, 180, 160)
        source[:9, 18:22] = (0, 255, 0)
        evidence = alpha.assess_green_background(source)
        self.assertGreater(evidence["green_source_border_ratio"], 0.02)

        cropped = np.zeros((24, 24, 3), dtype=np.uint8)
        cropped[:, :] = (210, 180, 160)
        cropped[8:16, 8:16] = (0, 255, 0)
        rgba = alpha.matte_frame(
            cropped,
            background_attested=True,
            background_rgb=tuple(evidence["background_rgb"]),
            reject_edge_contact=False,
        )
        self.assertEqual(int(rgba[0, :, 3].max()), 0)
        self.assertGreater(int(rgba[4:8, 4:8, 3].mean()), 200)


@unittest.skipIf(alpha.np is None, "NumPy is required")
class MacOSAlphaTransitionCompositeTests(unittest.TestCase):
    @staticmethod
    def _transition_frames():
        np = alpha.np
        assert np is not None
        height, width = 48, 64
        yy, xx = np.mgrid[0:height, 0:width]
        frames = []
        for center_x in (25.0, 39.0):
            distance = np.sqrt(((xx - center_x) / 1.15) ** 2 + (yy - 24.0) ** 2)
            alpha_values = np.clip((15.0 - distance) / 3.0, 0.0, 1.0)
            rgba = np.zeros((height, width, 4), dtype=np.uint8)
            rgba[:, :, :3] = (214, 184, 156)
            rgba[:, :, 3] = np.rint(alpha_values * 255.0).astype(np.uint8)
            frames.append(rgba)
        return frames

    @staticmethod
    def _lower_state_backgrounds(height: int, width: int):
        np = alpha.np
        assert np is not None
        yy, xx = np.mgrid[0:height, 0:width]

        running = np.empty((height, width, 3), dtype=np.uint8)
        running[:, :, 0] = 25 + (xx * 35 // max(width - 1, 1))
        running[:, :, 1] = 74 + (yy * 24 // max(height - 1, 1))
        running[:, :, 2] = 142

        waiting = np.empty((height, width, 3), dtype=np.uint8)
        waiting[:, :, 0] = 132
        waiting[:, :, 1] = 82 + (xx * 34 // max(width - 1, 1))
        waiting[:, :, 2] = 35 + (yy * 20 // max(height - 1, 1))

        checkerboard = alpha._background_pattern(
            "checkerboard", height=height, width=width
        )
        return {
            "running": running,
            "waiting": waiting,
            "checkerboard": checkerboard,
        }

    def test_layered_transition_composite_reveals_every_lower_state_without_fringe(self):
        np = alpha.np
        assert np is not None
        frames = self._transition_frames()
        backgrounds = self._lower_state_backgrounds(*frames[0].shape[:2])

        self.assertFalse(
            np.array_equal(backgrounds["running"], backgrounds["waiting"])
        )
        self.assertFalse(
            np.array_equal(frames[0][:, :, 3], frames[1][:, :, 3]),
            "the synthetic transition must exercise more than one visual frame",
        )
        for frame_index, rgba in enumerate(frames):
            with self.subTest(frame=frame_index, gate="alpha-contract"):
                alpha_values = rgba[:, :, 3]
                transparent = alpha_values == 0
                semitransparent = (alpha_values > 0) & (alpha_values < 255)
                opaque = alpha_values == 255

                self.assertGreater(
                    int(transparent.sum()), rgba.shape[0] * rgba.shape[1] // 2
                )
                self.assertGreater(int(semitransparent.sum()), 0)
                self.assertGreater(int(opaque.sum()), 0)
                self.assertFalse(bool(np.all(opaque)))
                self.assertTrue(bool(np.all(alpha_values[0, :] == 0)))
                self.assertTrue(bool(np.all(alpha_values[-1, :] == 0)))
                self.assertTrue(bool(np.all(alpha_values[:, 0] == 0)))
                self.assertTrue(bool(np.all(alpha_values[:, -1] == 0)))

                frame_metrics = alpha.frame_quality(
                    rgba,
                    max_outer_edge_alpha=alpha.DEFAULT_MAX_BORDER_ALPHA,
                )
                self.assertLessEqual(
                    frame_metrics["outer_edge_alpha_maximum"],
                    alpha.DEFAULT_MAX_BORDER_ALPHA,
                )
                composite_metrics = alpha.composite_quality(rgba)
                self.assertEqual(
                    composite_metrics["maximum_delivery_green_fringe_ratio"], 0.0
                )
                self.assertEqual(
                    composite_metrics["maximum_delivery_magenta_fringe_ratio"], 0.0
                )
                self.assertEqual(
                    composite_metrics["introduced_green_fringe_pixels"], 0
                )
                self.assertEqual(
                    composite_metrics["introduced_magenta_fringe_pixels"], 0
                )

            foreground = rgba[:, :, :3]
            composites = {}
            for background_name, background in backgrounds.items():
                with self.subTest(frame=frame_index, background=background_name):
                    composite = alpha.composite_rgba(rgba, background)
                    composites[background_name] = composite
                    self.assertTrue(
                        bool(
                            np.array_equal(
                                composite[transparent], background[transparent]
                            )
                        ),
                        "fully transparent transition pixels must reveal the lower layer exactly",
                    )
                    self.assertTrue(
                        bool(np.array_equal(composite[opaque], foreground[opaque])),
                        "fully opaque transition pixels must retain the foreground exactly",
                    )

                    lower = np.minimum(
                        foreground[semitransparent], background[semitransparent]
                    )
                    upper = np.maximum(
                        foreground[semitransparent], background[semitransparent]
                    )
                    blended = composite[semitransparent]
                    self.assertTrue(bool(np.all(blended >= lower)))
                    self.assertTrue(bool(np.all(blended <= upper)))
                    self.assertTrue(
                        bool(np.any(blended != background[semitransparent])),
                        "soft edges must contribute transition colour without hiding the lower layer",
                    )
                    self.assertTrue(
                        bool(np.any(blended != foreground[semitransparent])),
                        "soft edges must retain lower-layer contribution",
                    )
                    self.assertTrue(bool(np.array_equal(composite[0, 0], background[0, 0])))
                    self.assertTrue(
                        bool(np.array_equal(composite[-1, -1], background[-1, -1]))
                    )

            self.assertFalse(
                np.array_equal(
                    composites["running"][transparent],
                    composites["waiting"][transparent],
                ),
                "transparent regions must preserve distinct lower lifecycle states",
            )


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
                "--invocation-challenge",
                "a" * 64,
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
            self.assertEqual(payload["report_schema_version"], 1)
            self.assertEqual(payload["profile"]["name"], "standard")
            self.assertEqual(
                payload["provenance"],
                {
                    "method": "invocation-challenge-v1",
                    "producer": "statelet",
                    "challenge": "a" * 64,
                },
            )
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
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(intermediate.stat().st_mode & 0o777, 0o600)
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)
            played = subprocess.run(
                [
                    "swift",
                    "run",
                    "--package-path",
                    "mac/CodexPetMac",
                    "codex-pet-core-self-test",
                    "--playback-smoke",
                    str(output),
                    "64",
                    "48",
                    "24",
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
                timeout=180,
            )
            self.assertEqual(played.returncode, 0, played.stderr)
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
