-- tests/storefront_patch_mgr_test.lua
-- Unit tests for storefront_patch_mgr: SHA computation, record building, buildPatchSummary, update logic

require("tests/spec_helper")

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. package.path

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS\t" .. label)
    else
        failures = failures + 1
        print("FAIL\t" .. label)
    end
    io.stdout:flush()
end

local storefront_patch_mgr = require("storefront_patch_mgr")
local InstallStore = require("storefront_installs")
local Cache = require("storefront_cache")

print("=== Running Storefront Patch Manager Test Suite ===")

-- 1. Helper exports
check("exports init", type(storefront_patch_mgr.init) == "function")
check("exports listInstalledPatches", type(storefront_patch_mgr.listInstalledPatches) == "function")
check("exports getPatchRecordsMap", type(storefront_patch_mgr.getPatchRecordsMap) == "function")
check("exports buildPatchRecordFields", type(storefront_patch_mgr.buildPatchRecordFields) == "function")
check("exports buildPatchSummary", type(storefront_patch_mgr.buildPatchSummary) == "function")
check("exports computeFileSha1", type(storefront_patch_mgr.computeFileSha1) == "function")

-- 2. computeFileSha1 with Git blob format
do
    local tmp_path = script_dir .. "test_patch_blob.lua"
    local f = io.open(tmp_path, "wb")
    if f then
        f:write("return true\n")
        f:close()
    end

    local sha = storefront_patch_mgr.computeFileSha1(tmp_path)
    check("computeFileSha1 returns non-nil hash", sha ~= nil and type(sha) == "string" and #sha > 0)

    -- Missing or empty path returns nil
    check("computeFileSha1 returns nil for nil path", storefront_patch_mgr.computeFileSha1(nil) == nil)
    check("computeFileSha1 returns nil for empty path", storefront_patch_mgr.computeFileSha1("") == nil)
    check("computeFileSha1 returns nil for nonexistent file", storefront_patch_mgr.computeFileSha1("nonexistent_path_xyz.lua") == nil)

    os.remove(tmp_path)
end

-- 3. buildPatchRecordFields
do
    check("buildPatchRecordFields handles nil args", storefront_patch_mgr.buildPatchRecordFields(nil, nil, nil, false) == nil)
    check("buildPatchRecordFields handles empty filename", storefront_patch_mgr.buildPatchRecordFields("", {}, nil, false) == nil)

    local repo = { name = "myrepo", owner = "myowner", id = 123 }
    local patch_info = { branch = "main", path = "2-test.lua", sha = "abc12345" }
    local rec_with_sha = storefront_patch_mgr.buildPatchRecordFields("2-test.lua", repo, patch_info, true)
    check("buildPatchRecordFields with sha", rec_with_sha and rec_with_sha.sha == "abc12345")
    check("buildPatchRecordFields filename", rec_with_sha and rec_with_sha.filename == "2-test.lua")
    check("buildPatchRecordFields owner", rec_with_sha and rec_with_sha.owner == "myowner")

    local rec_no_sha = storefront_patch_mgr.buildPatchRecordFields("2-test.lua", repo, patch_info, false)
    check("buildPatchRecordFields without sha has nil sha", rec_no_sha and rec_no_sha.sha == nil)
end

-- 4. Storefront mixin methods initialization
do
    local mockStorefront = {}
    storefront_patch_mgr:init(mockStorefront)

    check("mixin listInstalledPatches", type(mockStorefront.listInstalledPatches) == "function")
    check("mixin collectPatchUpdateSummary", type(mockStorefront.collectPatchUpdateSummary) == "function")
    check("mixin buildPatchUpdateItems", type(mockStorefront.buildPatchUpdateItems) == "function")
    check("mixin updatePatchFromRecord", type(mockStorefront.updatePatchFromRecord) == "function")
    check("mixin matchPatchWithRepo", type(mockStorefront.matchPatchWithRepo) == "function")
    check("mixin updateSinglePatchStatus", type(mockStorefront.updateSinglePatchStatus) == "function")
    check("mixin _installPatchFromRepoInternal", type(mockStorefront._installPatchFromRepoInternal) == "function")
end

-- 5. updateSinglePatchStatus with remote_sha_override and cache invalidation
do
    local mockStorefront = {
        patch_updates_state = {},
        ensurePatchUpdatesState = function(self)
            self.patch_updates_state = self.patch_updates_state or {}
        end,
        savePatchUpdatesState = function(self)
            self._saved = true
        end,
        _cached_patch_summary = "stale_summary",
        _merged_updates_cache = "stale_merged",
        _cached_updates_count = 5,
    }
    storefront_patch_mgr:init(mockStorefront)

    local record = {
        filename = "2-foo.lua",
        owner = "user",
        repo = "repo",
        path = "2-foo.lua",
        sha = "old_local_sha",
    }
    mockStorefront:updateSinglePatchStatus("2-foo.lua", record, "new_remote_sha")

    local entry = mockStorefront.patch_updates_state.remote_info and mockStorefront.patch_updates_state.remote_info["2-foo.lua"]
    check("updateSinglePatchStatus saves remote_sha_override", entry and entry.remote_sha == "new_remote_sha")
    check("updateSinglePatchStatus persists state", mockStorefront._saved == true)
    check("updateSinglePatchStatus clears _cached_patch_summary", mockStorefront._cached_patch_summary == nil)
    check("updateSinglePatchStatus clears _merged_updates_cache", mockStorefront._merged_updates_cache == nil)
    check("updateSinglePatchStatus clears _cached_updates_count", mockStorefront._cached_updates_count == nil)
end

-- 6. updatePatchFromRecord fetches fresh remote SHA/download_url
do
    local mockStorefront = {
        patch_updates_state = {
            remote_info = {
                ["2-test.lua"] = {
                    remote_sha = "remote_sha_fresh",
                    download_url = "https://example.com/fresh.lua",
                }
            }
        },
        listInstalledPatches = function()
            return {
                { filename = "2-test.lua", path = "/tmp/2-test.lua" }
            }
        end,
    }
    storefront_patch_mgr:init(mockStorefront)

    local passed_repo, passed_patch
    mockStorefront.installPatchFromRepo = function(self, repo, patch_entry)
        passed_repo = repo
        passed_patch = patch_entry
    end

    local record = {
        filename = "2-test.lua",
        owner = "testowner",
        repo = "testrepo",
        path = "2-test.lua",
        sha = "stale_record_sha",
        download_url = "https://example.com/stale.lua",
    }
    mockStorefront:updatePatchFromRecord(record)

    check("updatePatchFromRecord passes fresh remote sha", passed_patch and passed_patch.sha == "remote_sha_fresh")
    check("updatePatchFromRecord passes fresh download_url", passed_patch and passed_patch.download_url == "https://example.com/fresh.lua")
    check("updatePatchFromRecord sets mode update in pending_patch_install", mockStorefront.pending_patch_install and mockStorefront.pending_patch_install.mode == "update")
end

if failures > 0 then
    error(string.format("Storefront Patch Manager tests failed: %d errors", failures))
end
print("Storefront Patch Manager test suite completed successfully.")
