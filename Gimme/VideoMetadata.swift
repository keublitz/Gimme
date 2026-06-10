// sam wiener 2026, all rights reserved

struct VideoMetadata: Codable {
    /// The unique identifier of the video.
    let id: String
    
    let title: String
    
    /// The duration of the video in seconds.
    let duration: Int // in seconds
    
    // detailed description of format ID and type
    let format_id: String
    
    let ext: String
    
    /// The file extension of the video.
    let video_ext: String
    
    /// The file extension of the audio.
    let audio_ext: String
    
    /// The approximate filesize of the video in bytes.
    let filesize_approx: Int
    
    let width: Int
    
    let height: Int
    
    let resolution: String
    
    /// The dynamic range of the video.
    let dynamic_range: String
    
    /// The codec of the video.
    let vcodec: String
    
    /// The codec of the audio.
    let acodec: String
    
    init(id: String = "", title: String = "", duration: Int = 0, format_id: String = "", ext: String = "", video_ext: String = "", audio_ext: String = "", filesize_approx: Int = 0, width: Int = 0, height: Int = 0, resolution: String = "", dynamic_range: String = "", vcodec: String = "", acodec: String = "") {
        self.id = id
        self.title = title
        self.duration = duration
        self.format_id = format_id
        self.ext = ext
        self.video_ext = video_ext
        self.audio_ext = audio_ext
        self.filesize_approx = filesize_approx
        self.width = width
        self.height = height
        self.resolution = resolution
        self.dynamic_range = dynamic_range
        self.vcodec = vcodec
        self.acodec = acodec
    }
}

extension VideoMetadata {
    static var jsonScript: String {
        """
        {
            "id": "%(id)s", 
            "title": "%(title)s", 
            "duration": %(duration|0)s, 
            "format_id": "%(format_id)s",
            "ext": "%(ext)s",
            "video_ext": "%(video_ext)s", 
            "audio_ext": "%(audio_ext)s", 
            "filesize_approx": %(filesize_approx|0)s, 
            "width": %(width|0)s, 
            "height": %(height|0)s, 
            "resolution": "%(resolution)s", 
            "dynamic_range": "%(dynamic_range)s", 
            "vcodec": "%(vcodec)s", 
            "acodec": "%(acodec)s"
        }
        """
    }
}

struct RequestedFormat: Codable {
    
    let filesize: Int // bytes
    let format_id: String
    let format_note: String // resolution + dynamic range
    
    let height: Int?
    
    let filesize_approx: Int // bytes
    let width: Int?
    
    let ext: String
    let vcodec: String
    let acodec: String
    let dynamic_range: String?
    
    let video_ext: String
    let audio_ext: String
    let resolution: String
    
    let format: String
}

struct VideoThumbnail: Codable {
    
}
