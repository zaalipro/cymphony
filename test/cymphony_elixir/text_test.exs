defmodule CymphonyElixir.TextTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Text

  describe "strip_ansi_and_control/1" do
    test "removes CSI sequences, other escapes, and control bytes" do
      raw = "\e[2J\e[H\eMstatus\r\n\x00ok\x7F"

      assert Text.strip_ansi_and_control(raw) == "statusok"
    end

    test "leaves plain text untouched" do
      assert Text.strip_ansi_and_control("invalid model selection") == "invalid model selection"
    end
  end

  describe "truncate_trailing_bytes/2" do
    test "returns the value untouched when it fits the cap" do
      assert Text.truncate_trailing_bytes("abcdef", 6) == "abcdef"
    end

    test "keeps the head when the value exceeds the cap" do
      assert Text.truncate_trailing_bytes("real error\nnoise", 10) == "real error"
    end

    test "drops the trailing bytes of a codepoint split by the cut" do
      # "𝄞" is 4 bytes; cutting to the first 6 bytes leaves 2 of them.
      assert Text.truncate_trailing_bytes("abc𝄞", 6) == "abc"
      assert String.valid?(Text.truncate_trailing_bytes("abc𝄞", 6))
    end

    test "returns an empty string for a zero cap" do
      assert Text.truncate_trailing_bytes("abc", 0) == ""
    end
  end

  describe "scrub_invalid_utf8/1" do
    test "returns valid input unchanged" do
      assert Text.scrub_invalid_utf8("plain ✓ text") == "plain ✓ text"
    end

    test "drops byte runs that are not valid UTF-8" do
      scrubbed = Text.scrub_invalid_utf8("ok-" <> <<0xE2, 0x9C>> <> "-mid-" <> <<0xFF>> <> "-end")

      assert scrubbed == "ok--mid--end"
      assert String.valid?(scrubbed)
    end

    test "produces a binary IO.puts/2 accepts" do
      scrubbed = Text.scrub_invalid_utf8(<<0x9C>> <> "tail")

      assert ExUnit.CaptureIO.capture_io(fn -> IO.puts(scrubbed) end) == "tail\n"
    end
  end
end
