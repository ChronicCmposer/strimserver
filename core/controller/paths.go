package main

import (
   "errors"
   "fmt"
   "path"
)

// Container-internal mount destinations. These are a contract with the scripts
// that get mounted (transcode.sh, notify.sh, entrypoint.mediamtx.sh); changing
// one means changing that script too. NOT independently configurable.
const (
   ctrEnv          = "/strimserver.env"
   ctrTranscode    = "/transcode.sh"
   ctrNotify       = "/notify.sh"
   ctrMediaMTXTmpl = "/mediamtx.yaml.template" // must equal MEDIAMTX_CONFIG_TEMPLATE
   ctrSrtSecret    = "/run/secrets/srt-passphrase"
   ctrVideoDir     = "/video-files"
   ctrResolvConf   = "/etc/resolv.conf"
   ctrTmp          = "/tmp"
)

type Layout struct {
   Env, Transcode, Notify, MediaMTXTmpl, SrtPass, VideoDir, ResolvConf, Tmp string
}

func DefaultLayout(hostRoot string) Layout {
   if hostRoot == "" {
      hostRoot = "/mnt/nvme"
   }
   cfg, bin := path.Join(hostRoot, "config"), path.Join(hostRoot, "bin")
   return Layout{
      Env:          path.Join(cfg, "strimserver.env"),
      Transcode:    path.Join(bin, "transcode.sh"),
      Notify:       path.Join(bin, "notify.sh"),
      MediaMTXTmpl: path.Join(cfg, "mediamtx.yaml.template"),
      SrtPass:      path.Join(hostRoot, "srt-passphrase"),
      VideoDir:     path.Join(hostRoot, "video-files"),
      ResolvConf:   "/run/systemd/resolve/resolv.conf", // system path, not under hostRoot
      Tmp:          "/tmp",
   }
}

func (l Layout) validate() error {
   var errs []error
   for _, f := range []struct{ name, val string }{
      {"Env", l.Env}, {"Transcode", l.Transcode}, {"Notify", l.Notify},
      {"MediaMTXTmpl", l.MediaMTXTmpl}, {"SrtPass", l.SrtPass},
      {"VideoDir", l.VideoDir}, {"ResolvConf", l.ResolvConf}, {"Tmp", l.Tmp},
   } { if f.val == "" { errs = append(errs, fmt.Errorf("layout.%s is empty", f.name)) } }
   return errors.Join(errs...)
}


