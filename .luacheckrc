-- .luacheckrc
std = "luajit"
unused_args = false
self = false

globals = {
    "_",
    "_G",
    "G_reader_settings",
    "G_defaults",
    "G_storefront_batch_updating",
}

ignore = {
    "631", -- line is too long
}
