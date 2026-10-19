package.path = "storefront.koplugin/?.lua;" .. package.path

local storefront_installer = require("storefront_installer")

describe("storefront_installer", function()
    it("exports required helper functions", function()
        assert.is_table(storefront_installer)
        assert.is_function(storefront_installer.init)
        assert.is_function(storefront_installer.downloadToFile)
        assert.is_function(storefront_installer.detectPluginFromArchive)
        assert.is_function(storefront_installer.extractPluginToUserDir)
    end)

    it("initializes Storefront installer mixin methods", function()
        local mockStorefront = {}
        storefront_installer:init(mockStorefront)

        assert.is_function(mockStorefront.resolveNewInstallDestination)
        assert.is_function(mockStorefront.renderAssetPickerModal)
        assert.is_function(mockStorefront.renderBranchPickerModal)
        assert.is_function(mockStorefront.showBranchPickerDialog)
        assert.is_function(mockStorefront.promptPluginInstallOptions)
        assert.is_function(mockStorefront.installPluginFromRepo)
        assert.is_function(mockStorefront._installPluginFromRepoInternal)
        assert.is_function(mockStorefront.installPluginFromReleaseAsset)
        assert.is_function(mockStorefront.installPluginFromBranch)
    end)

    describe("downloadToFile validation", function()
        it("returns false for missing URL", function()
            local ok, err = storefront_installer.downloadToFile("", "target.zip")
            assert.is_false(ok)
            assert.is_string(err)
        end)
    end)

    describe("native library staging and crash prevention (Issue #5077)", function()
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local test_tmp_dir = "/tmp/test_storefront_installer_" .. os.time()

        before_each(function()
            storefront_installer.clearStagedNativeLibs()
            util.makePath(test_tmp_dir)
        end)

        after_each(function()
            storefront_installer.clearStagedNativeLibs()
            -- Cleanup test tmp dir
            local function cleanupDir(p)
                if lfs.attributes(p, "mode") == "directory" then
                    for f in lfs.dir(p) do
                        if f ~= "." and f ~= ".." then
                            cleanupDir(p .. "/" .. f)
                        end
                    end
                    lfs.rmdir(p)
                elseif lfs.attributes(p, "mode") == "file" then
                    os.remove(p)
                end
            end
            cleanupDir(test_tmp_dir)
        end)

        it("correctly identifies native shared library paths", function()
            assert.is_true(storefront_installer.isNativeLibraryPath("libhoedown.so"))
            assert.is_true(storefront_installer.isNativeLibraryPath("lib/armv7_softfp/libhoedown.so.3"))
            assert.is_true(storefront_installer.isNativeLibraryPath("lib/x86_64/libsqlite3.so.0.8.6"))
            assert.is_true(storefront_installer.isNativeLibraryPath("custom.so"))

            assert.is_false(storefront_installer.isNativeLibraryPath("main.lua"))
            assert.is_false(storefront_installer.isNativeLibraryPath("_meta.lua"))
            assert.is_false(storefront_installer.isNativeLibraryPath("libhoedown.so.new"))
            assert.is_false(storefront_installer.isNativeLibraryPath("libhoedown.so.bak"))
            assert.is_false(storefront_installer.isNativeLibraryPath("libhoedown.so.txt"))
            assert.is_false(storefront_installer.isNativeLibraryPath(nil))
            assert.is_false(storefront_installer.isNativeLibraryPath(123))
        end)

        it("extracts fresh native libraries directly when target does not exist", function()
            local extracted_paths = {}
            local mock_reader = {
                iterate = function(self)
                    local entries = {
                        { path = "assistant.koplugin/main.lua", mode = "file" },
                        { path = "assistant.koplugin/lib/libhoedown.so.3", mode = "file" },
                    }
                    local i = 0
                    return function()
                        i = i + 1
                        return entries[i]
                    end
                end,
                extractToPath = function(self, src_path, dst_path)
                    extracted_paths[dst_path] = true
                    local f = io.open(dst_path, "w")
                    if f then
                        f:write("NEW_CONTENT")
                        f:close()
                    end
                    return true
                end,
            }

            local info = {
                plugin_dirname = "assistant.koplugin",
                prefix = "assistant.koplugin/",
            }

            local ok, res = storefront_installer.extractPluginToUserDir(mock_reader, info, test_tmp_dir)
            assert.is_true(ok)

            local expected_target = test_tmp_dir .. "/assistant.koplugin/lib/libhoedown.so.3"
            assert.is_true(extracted_paths[expected_target])
            assert.is_nil(extracted_paths[expected_target .. ".new"])
            assert.are.same(0, #storefront_installer.getStagedNativeLibs())
        end)

        it("stages existing native libraries as .new during updates without touching mapped .so", function()
            local target_dir = test_tmp_dir .. "/assistant.koplugin"
            local lib_dir = target_dir .. "/lib"
            util.makePath(lib_dir)
            local existing_so = lib_dir .. "/libhoedown.so.3"

            -- Write existing (mapped) .so file
            local f = io.open(existing_so, "w")
            f:write("OLD_MAPPED_SO_CONTENT")
            f:close()

            local extracted_paths = {}
            local mock_reader = {
                iterate = function(self)
                    local entries = {
                        { path = "assistant.koplugin/main.lua", mode = "file" },
                        { path = "assistant.koplugin/lib/libhoedown.so.3", mode = "file" },
                    }
                    local i = 0
                    return function()
                        i = i + 1
                        return entries[i]
                    end
                end,
                extractToPath = function(self, src_path, dst_path)
                    extracted_paths[dst_path] = true
                    local f_out = io.open(dst_path, "w")
                    if f_out then
                        f_out:write("NEW_VERSION_SO_CONTENT")
                        f_out:close()
                    end
                    return true
                end,
            }

            local info = {
                plugin_dirname = "assistant.koplugin",
                prefix = "assistant.koplugin/",
            }

            local ok, res = storefront_installer.extractPluginToUserDir(mock_reader, info, test_tmp_dir)
            assert.is_true(ok)

            -- The existing .so file must NOT have been overwritten while mapped!
            local f_orig = io.open(existing_so, "r")
            local orig_content = f_orig:read("*a")
            f_orig:close()
            assert.are.same("OLD_MAPPED_SO_CONTENT", orig_content)

            -- The new version was extracted to .new
            local staged_so = existing_so .. ".new"
            local f_staged = io.open(staged_so, "r")
            assert.is_not_nil(f_staged)
            local staged_content = f_staged:read("*a")
            f_staged:close()
            assert.are.same("NEW_VERSION_SO_CONTENT", staged_content)

            -- It is recorded in the staged queue
            local queue = storefront_installer.getStagedNativeLibs()
            assert.are.same(1, #queue)
            assert.are.same(staged_so, queue[1].staged)
            assert.are.same(existing_so, queue[1].target)

            -- Now simulate applying staged libs at shutdown
            storefront_installer.applyStagedNativeLibs()

            -- Verify target now has new content and .new is removed
            local f_after = io.open(existing_so, "r")
            local after_content = f_after:read("*a")
            f_after:close()
            assert.are.same("NEW_VERSION_SO_CONTENT", after_content)
            assert.are.same("file", lfs.attributes(existing_so, "mode"))
            assert.is_nil(lfs.attributes(staged_so, "mode"))
            assert.are.same(0, #storefront_installer.getStagedNativeLibs())
        end)

        it("safe exit hook swaps staged native libs and prevents lua_close on exit code 85", function()
            local target_dir = test_tmp_dir .. "/testplugin.koplugin"
            util.makePath(target_dir)
            local target_so = target_dir .. "/test.so"
            local staged_so = target_so .. ".new"

            local f_old = io.open(target_so, "w")
            f_old:write("OLD")
            f_old:close()

            local f_new = io.open(staged_so, "w")
            f_new:write("NEW")
            f_new:close()

            storefront_installer.stageNativeLibrary(staged_so, target_so)
            assert.is_true(storefront_installer.hasPendingNativeLibExitHazard())

            _G._STOREFRONT_TEST_NO_POSIX_EXIT = true
            local exit_code_received, close_state_received = nil, nil
            local orig_os_exit = _G.os.exit
            _G.os.exit = function(code, close_state)
                exit_code_received = code
                close_state_received = close_state
            end

            storefront_installer.installSafeExitHook()

            -- Trigger KOReader restart exit
            _G.os.exit(85, true)

            -- Staged libs swapped
            local f_check = io.open(target_so, "r")
            assert.are.same("NEW", f_check:read("*a"))
            f_check:close()
            assert.is_nil(lfs.attributes(staged_so, "mode"))

            -- In safe exit fallback, exit code 85 was forwarded with close_state = false (bypassing lua_close)
            assert.are.same(85, exit_code_received)
            assert.are.same(false, close_state_received)

            _G._STOREFRONT_TEST_NO_POSIX_EXIT = nil
            _G.os.exit = orig_os_exit
        end)
    end)
end)
