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

  describe "redact_secrets/1" do
    test "redacts NAME=value assignments and keeps the variable name" do
      assert Text.redact_secrets("LINEAR_API_KEY=lin_api_abcdefghij0123456789") ==
               "LINEAR_API_KEY=[REDACTED]"

      assert Text.redact_secrets("export ANTHROPIC_API_KEY=sk-ant-api03-AAAABBBBCCCC") ==
               "export ANTHROPIC_API_KEY=[REDACTED]"

      assert Text.redact_secrets("GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123") == "GH_TOKEN=[REDACTED]"
      assert Text.redact_secrets("MY_SECRET_TOKEN = abc123") == "MY_SECRET_TOKEN = [REDACTED]"
      assert Text.redact_secrets("db_password=hunter2") == "db_password=[REDACTED]"
      assert Text.redact_secrets("credential.helper=store") == "credential.helper=[REDACTED]"
    end

    test "redacts NAME: value and quoted JSON assignments" do
      assert Text.redact_secrets("password: hunter2") == "password: [REDACTED]"

      assert Text.redact_secrets(~s({"api_key": "lin_api_zzzz", "model": "sonnet"})) ==
               ~s({"api_key": "[REDACTED]", "model": "sonnet"})

      # The JSON form must win over the bare `\\S+` forms: its value may contain
      # spaces, which the colon form would leave dangling in the clear.
      assert Text.redact_secrets(~s({"client_secret": "two words here"})) ==
               ~s({"client_secret": "[REDACTED]"})

      assert Text.redact_secrets(~s({"api_key":"packed"})) == ~s({"api_key":"[REDACTED]"})
    end

    test "redacts Authorization headers with and without a Bearer scheme" do
      assert Text.redact_secrets("Authorization: Bearer abc.def.ghi") == "Authorization: Bearer [REDACTED]"
      assert Text.redact_secrets("authorization: lin_api_plain") == "authorization: [REDACTED]"
      assert Text.redact_secrets("AUTHORIZATION=Bearer tok123") == "AUTHORIZATION=Bearer [REDACTED]"
    end

    test "redacts bare vendor-prefixed credentials anywhere in the line" do
      cases = [
        "failed with sk-ant-api03-AAAABBBBCCCCDDDD",
        "key lin_api_abcdefghij0123456789 rejected",
        "remote uses ghp_abcdefghijklmnopqrstuvwxyz0123",
        "token github_pat_11ABCDEFG0123456789_abcdefghijklmnop expired",
        "slack xoxb-123456-abcdefghij failed",
        "gemini AIzaSyA12345678901234567890123456789012 denied"
      ]

      Enum.each(cases, fn line ->
        assert Text.redact_secrets(line) =~ "[REDACTED]"
        refute Text.redact_secrets(line) =~ "sk-ant"
        refute Text.redact_secrets(line) =~ "lin_api_"
        refute Text.redact_secrets(line) =~ "ghp_"
        refute Text.redact_secrets(line) =~ "github_pat_"
        refute Text.redact_secrets(line) =~ "xoxb-"
        refute Text.redact_secrets(line) =~ "AIzaSy"
      end)
    end

    test "leaves ordinary agent output untouched" do
      untouched = [
        "error: unknown provider for model",
        "the monkey ate a banana",
        "MONKEY=banana",
        "TOKENIZER_PATH=/usr/lib/tok",
        "keyboard shortcut: ctrl+k",
        "https://api.linear.app/graphql?first=50",
        "commit a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
        "def key_for(x), do: x",
        ~s({"type":"result","subtype":"success"}),
        ""
      ]

      Enum.each(untouched, fn line ->
        assert Text.redact_secrets(line) == line
      end)
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
