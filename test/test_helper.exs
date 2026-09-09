ExUnit.start()

test_inbox = Application.fetch_env!(:ai_pair, :inbox)
ExUnit.after_suite(fn _result -> File.rm_rf!(test_inbox) end)
