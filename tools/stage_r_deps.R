# tools/stage_r_deps.R — print the transitive closure of the packages the app
# needs, as full paths to each installed package directory, EXCLUDING base +
# recommended packages (those ship inside the R runtime's own library and are
# copied with it). stage_r.ps1 copies each printed directory into bin\R\library.
want <- c("shiny","bslib","DT","jsonlite","openssl","sodium","data.table",
          "future","future.apply","readxl","writexl","xml2","pdftools",
          "tesseract","magick","sdcMicro","mirai")
ip <- installed.packages()
have <- rownames(ip)
miss <- setdiff(want, have)
if (length(miss))
  stop("Not installed on this build machine: ", paste(miss, collapse = ", "))

dep <- tools::package_dependencies(want, db = ip, recursive = TRUE,
                                   which = c("Depends", "Imports", "LinkingTo"))
all <- unique(c(want, unlist(dep, use.names = FALSE)))
all <- all[all %in% have]

prio <- ip[, "Priority"]
shipped <- rownames(ip)[!is.na(prio) & prio %in% c("base", "recommended")]
all <- setdiff(all, shipped)

for (p in sort(all)) cat(file.path(ip[p, "LibPath"], p), "\n", sep = "")
