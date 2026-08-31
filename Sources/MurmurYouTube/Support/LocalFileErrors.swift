import Foundation

func isMissingLocalFile(_ error: Error) -> Bool {
    let value = error as NSError
    if value.domain == NSCocoaErrorDomain,
       value.code == CocoaError.fileReadNoSuchFile.rawValue {
        return true
    }
    if value.domain == NSPOSIXErrorDomain,
       value.code == POSIXErrorCode.ENOENT.rawValue {
        return true
    }
    if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
        return isMissingLocalFile(underlying)
    }
    return false
}
