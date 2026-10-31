<div align="center">

# Lilo

**Arc tarzı Mac tarayıcısı; Chromium değil, WebKit üzerinde.**

Chrome uzantılarınız, sayfalarınızın yanında terminal sekmeleri ve yapay zekâ ajanlarınız için yerleşik bir MCP sunucusu. Ücretsiz, açık kaynak, hesap gerektirmez.

[![macOS için indir](https://img.shields.io/badge/macOS%20i%C3%A7in%20indir-6a4be0?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)

`brew install --cask alexays/tap/lilo` · macOS 26 veya üstü

[![Release](https://img.shields.io/github/v/release/Alexays/Lilo?color=e07a4b)](https://github.com/Alexays/Lilo/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Alexays/Lilo/total?color=6a4be0)](https://github.com/Alexays/Lilo/releases)
[![Stars](https://img.shields.io/github/stars/Alexays/Lilo?color=6a4be0)](https://github.com/Alexays/Lilo/stargazers)
[![Lisans: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)

[Web sitesi](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Arc'tan geçiş](#arctan-geçiş) ·
[Belgeler](../../docs/README.md) ·
[Katkıda bulunma](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/assets/lilo-dark.png">
  <img src="../../docs/assets/lilo-light.png" alt="İş Alanı açıkken Lilo: web sayfası ve terminal sekmesinin yanında sabitlenmiş siteler, klasörler ve sekmeler içeren kenar çubuğu" width="900">
</picture>

<sub>[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md) · [Italiano](README_it.md) · [한국어](README_ko.md) · [繁體中文](README_zh-Hant.md) · [Polski](README_pl.md) · **Türkçe** · [Nederlands](README_nl.md)</sub>

</div>

Lilo, kenar çubuğundan vazgeçemeyenler için bir Mac tarayıcısıdır; bir başka Chromium çatallaması değildir.
Swift ve AppKit ile geliştirilmiş yerel bir uygulamadır ve macOS'te zaten bulunan WebKit motorunu kullanır.
Buna rağmen güvendiğiniz Chrome genişletmelerini çalıştırır. Terminal sekmelerini sayfalarınızın yanına
getirir ve zaten kullandığınız yapay zekâ ajanlarının yerleşik MCP sunucusu üzerinden kendi Alanlarında
Lilo'yu yönetmesini sağlar. Ücretsizdir, MIT lisanslıdır ve hesap gerektirmez. Arc'tan geçiyorsanız
Alanlarınızı, sabitlenmiş sekmelerinizi ve klasörlerinizi birkaç tıklamayla içe aktarır.

> **Durum: herkese açık beta.** Lilo her gün kullanılabilir, ancak hâlâ beta aşamasındadır. Pürüzlerle
> ve değişmeye devam eden bir arayüzle karşılaşabilirsiniz. Lütfen
> [karşılaştığınız sorunları bildirin](https://github.com/Alexays/Lilo/issues).
> Öncelikler ve kapsam dışı hedefler [ROADMAP.md](../../ROADMAP.md) dosyasında listelenir.

Geri bildirim paylaşmak ve Lilo için yardım almak üzere [Discord topluluğuna](https://discord.gg/NyJRAapk76) katılın.

## Arc'tan geçiş

Arc, 22 Aralık 2026'da kapanıyor. Lilo, kenar çubuğuyla gezinme alışkanlığını korur ve Arc'taki her şeyi doğrudan Mac'inizden içe aktarır; Arc'ta hiçbir şeyi değiştirmez:

- **Alanlar, sekmeler ve bölünmüş görünümler**: her Arc alanı; simgesi ve rengi, sabitlenmiş ve açık sekmeleri, klasörleri ve bölünmüş görünümleriyle bir Lilo alanı olur. Favoriler yer imi sekmelerine dönüşür.
- **Geçmiş ve oturumlar**: son sayfalarınız komut çubuğunda görünür, çerezler de kopyalanır; böylece oturumunuz açık kalır.
- **Uzantılar**: Chrome Web Mağazası'ndan gelenler mağazadan yeniden yüklenir. Hangilerini seçeceğinize siz karar verirsiniz.
- **Kısayollar**: Arc hazır ayarıyla başlayın, sonra istediğinizi değiştirin.

Değişen şey motor: Chromium yerine WebKit. Aynı sekmelerle Chrome, Lilo'nun yaklaşık 3 katı enerji harcar ([ölçüm](../ENERGY.md)) ve bazı Chrome uzantı API'leri hâlâ farklıdır ([COMPATIBILITY.md](../../COMPATIBILITY.md)). [Arc alternatifi sayfası](https://getlilo.app/arc-alternative/) ikisini özellik özellik karşılaştırır.

## Neden Lilo

Çoğu Arc alternatifi, yeni bir kenar çubuğu eklenmiş Chromium'dur. Lilo kenar çubuğunu korur, geri kalanını değiştirir.

- **Chromium değil.** Paketlenmiş tarayıcı motoru yok, Electron yok: Swift, AppKit ve sistemin WebKit'i;
  kenar çubuğu ve ayarlar ise Svelte ile geliştirilir. Daha düşük bellek kullanımı, günü çıkaran pil
  ve her macOS sürümüyle gelen Apple güvenlik güncellemeleri.
- **İlk andan itibaren gizlilik.** Hesap, telemetri, analiz, sunucu yok: Yaptığınız hiçbir şey projeye
  gönderilmez. Reklamlar ve izleyiciler baştan engellenir, Safari'deki gibi siteler arası takip önlenir
  ve Global Privacy Control açıktır (macOS 27). Lilo'nun kendiliğinden yaptığı her istek,
  [kapatma yöntemiyle birlikte listelenir](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Chrome genişletmeleriniz yine sizinle.** Chromium'dan ayrılmak genellikle genişletmelerden de ayrılmak
  demektir. Lilo'da Chrome Web Mağazası genişletmeleri “Lilo'ya Ekle” düğmesine tek tıklamayla kurulur
  ve WebKit'in yerel çalışma ortamında çalışır ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Ajanlarınız yönetir; Lilo'nun kendi yapay zekâsı yoktur.** Sonradan eklenmiş bir sohbet botu yoktur.
  Zaten çalıştırdığınız ajanlar (Claude Code, Codex, Cursor veya herhangi bir MCP istemcisi), yerleşik
  MCP sunucusu üzerinden gerçek bir tarayıcı kullanır. Kendi Alanlarında ve geçici profillerinde
  çalışır, göndermeden, ödemeden veya silmeden önce size sorarlar.
- **Sayfalarınızın yanında terminal.** Ghostty tabanlı terminal sekmeleri sitelerinizle birlikte kenar
  çubuğunda yer alır; depolarının dalını ve bekleyen değişikliklerini gösterir.
- **Sizin tarayıcınız.** MIT lisanslıdır. Tüm arayüz, WebKit üzerinde çalışan bir Svelte katmanıdır;
  istediğiniz gibi değiştirip saniyeler içinde yeniden derleyebilirsiniz.

## Özellikler

**Web'de gezinme**

- **Alanlar ve profiller**: Emojisi ve rengi olan Alanlar, her biri kendi profiliyle oturum açar.
  Kaydırarak aralarında geçiş yapın. Özel Alanlar kapandıklarında her şeyi unutur.
- **Kenar çubuğu**: Sabitlenmiş sekmeler, favoriler, beş düzeye kadar iç içe ve kilitlenebilir klasörler,
  sürükleyerek sıralama, ses ve çalan içerik denetimleri.
- **Komut çubuğu** (`Cmd+T`): Sekmeler, geçmiş, yer imleri, Alanlar ve tüm işlemler tek alanda;
  kullanımınıza göre sıralanır.
- **Son sekmeler** (`Ctrl+Tab`): Tüm Alanlardaki son sekmeleriniz arasında kullanım sırasıyla geçiş yapın.
- **Önizleme**: Sabitlenmiş sekmeden başka bir siteye giden bağlantı veya `Shift` ile tıklanan herhangi
  bir bağlantı sayfanın üzerinde açılır.
- **Küçük pencere** (`Cmd+Option+N`, her uygulamadan): Tek bir bağlantı veya arama için küçük bir
  pencere. İş büyüdüğünde bir Alana gönderebilirsiniz.
- **Kendi kendini toplayan sekmeler**: Kullanmayı bıraktığınız sabitlenmemiş sekmeler, her Alan için
  seçtiğiniz sürenin ardından arşivlenir. `Cmd+Shift+K` bunları temizler; arşiv tek tuş uzağınızdadır.
- **Bağlantı kuralları**: Diğer uygulamalardan açılan bağlantılar, kuralın seçtiği Alana veya Küçük
  pencereye gider.
- **Bölünmüş görünüm**: Dört sekmeye kadar yan yana görüntüleme; yeniden açılışta geri yüklenir.
- **Kestirmeler**: Lilo veya Arc önayarından başlayarak her kestirmeyi değiştirebilirsiniz.
- **İçe aktarma**: Safari, Firefox, Zen ve Chromium tarayıcılarından (Chrome, Arc, Brave, Edge,
  Vivaldi, Opera, Dia, Comet, Chromium) yer imleri, açık sekmeler ve Alanlar, geçmiş, çerezler ve
  genişletmeler doğrudan Mac'inizden okunur.

**Genişletmeler ve web**

- **Chrome genişletmeleri**: WebKit'in yerel genişletme çalışma ortamıyla Manifest V3 desteği ve
  WebKit'te bulunmayan API'ler için küçük Swift işleyicileri ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Parola yöneticileri**: Kurulum, kullandığınız yöneticiyi sunar (1Password, Bitwarden, Dashlane,
  KeePassXC, NordPass, Proton Pass).
- **Akış**: FairPlay ile korumalı video ve müzik; 4K HDR YouTube.
- **İçerik engelleme**: Güncel tutulan EasyList, EasyPrivacy ve uBlock Origin listeleri; kozmetik
  filtreleme ve küçük betiklerle birlikte.
- **Ekran resimleri**: Çekilen görüntü sayfanın üzerinde bir kart olarak durur. İşaretleyerek
  düzenleyebilir, kaydedebilir veya kapatabilirsiniz.
- **Daha fazlası**: Okuyucu modu, Resim İçinde Resim (aramalar her zaman üstte kalan panelde görünür),
  sayfa çevirisi, Web Serial, AppleScript, Kestirmeler işlemleri ve Odak filtresi.

**Geliştirenler için**

- **Terminal sekmeleri**: Metal oluşturucusu üzerinde libghostty-vt terminalleri sayfalarınızın
  yanında (`Cmd+D` yana, `Cmd+Shift+D` alta), dal ve bekleyen değişiklikler kenar çubuğunda.
- **Değişiklik görünümü**: Görüntüler dahil deponun tüm farkları.
- **Çalışırken uyanık kalır**: Uzun süren komut Mac'i kapak kapalıyken bile uyanık tutar,
  ardından uyumasına izin verir.
- **MCP üzerinden ajanlar**: Yerleşik MCP sunucusu; [Yapay zekâ ajanları için](#yapay-zekâ-ajanları-için) bölümüne bakın.

## Yapay zekâ ajanları için

Lilo'nun yerleşik bir MCP sunucusu vardır. Açtığınızda zaten çalıştırdığınız ajanlar (Claude Code,
Claude Desktop, Codex, Cursor veya herhangi bir MCP istemcisi) yanınızda gerçek bir WebKit tarayıcısını
yönetir. Lilo kendi yapay zekâsını içermez.

- **Kendi Alanları.** Ajanlar sekmelerini Ajanlar Alanındaki bir klasörde, her oturumdan sonra
  silinen geçici bir profilde açar. Klavyenizi, farenizi veya sekmelerinizi devralmaz, Özel Alanları
  asla görmezler. İzin verdiğinizde profillerinizden birini ödünç alabilirler.
- **Önce siz onaylarsınız.** Ajan göndermeden, ödemeden, silmeden veya yayımlamadan önce Lilo size
  sorar (Bir Kez İzin Ver, Bu Sitede Her Zaman İzin Ver veya Reddet). Dosyalarınızdan birini sayfaya
  vermeden önce de sorar. Her istemci bir kez onaylanır; kimliği verdiği ada değil, arkasındaki
  programa bağlıdır.
- **Tek tıklamayla bağlantı.** Ayarlar > Yapay zekâ ajanları bölümünde “Yapay zekâ ajanları Lilo'yu
  kullanabilsin” seçeneğini açın. Ardından Claude Code, Claude Desktop, Codex veya Cursor yanındaki
  Bağlan'a basın. Lilo kendini istemcinin MCP sunucularına ekler. Diğer istemciler için “Diğer ajanlar”
  bölümünden yapılandırmayı kopyalayın.

Ardından ajanınıza şöyle bir istekte bulunun:

```text
Lilo'da localhost:3000/checkout adresini aç, test kartıyla ödeme yap ve siparişin neden başarısız olduğunu bul.
Konsolu ve ağı denetle.
```

Araçlar şunları kapsar:

- **Sekmeler ve gezinme**: Ajanın klasöründeki sekmeler ve çerez ya da oturum paylaşmayan yalıtılmış sekmeler.
- **Girdi**: Tıklama, yazma, tuşlar, kaydırma, sürükleme, form doldurma, dosya ve görüntü yükleme.
- **Sayfa okuma**: Öğe referanslarıyla erişilebilirlik ağacı, metin arama, sayfa metni.
- **Ekran resimleri**: Tüm sayfa veya tek bir öğe ve GIF kayıtları.
- **Konsol ve ağ**: İletiler, tam yanıtlarıyla istekler, HAR dışa aktarma, çerezler.
- **Sahte ağ yanıtları ve benzetim**: Sahte, başarısız veya gecikmiş istekler; kullanıcı aracısı,
  renk düzeni, azaltılmış hareket, yazdırma ortamı, ek başlıklar, başlangıç betikleri; görüntü alanı boyutu.
- **Performans**: Yükleme ve çizim ölçümleri, bellek ve zaman çizelgesi profilleri.
- **Web Denetçisi**: WebKit'in kendi denetçi protokolü, komutları ve olayları.
- **Betikler**: Sayfada JavaScript, sekmenin çerezleriyle `fetch` ve birçok çağrıyı tek bir gidiş
  dönüşte birleştirmek için `run` veya `browser_batch`.
- **Profiller**: Listeleme, izninizden sonra birini ödünç alma veya geçici profili sıfırlama.

[docs/AI-AGENTS.md](../../docs/AI-AGENTS.md), hangi işlemlerin onay gerektirdiğini, hangilerinin
gerektirmediğini ve müdahalenize ihtiyaç duyan hataları açıklar.

## Kurulum

Şu yöntemlerden birini seçin:

- [Sürümler](https://github.com/Alexays/Lilo/releases/latest) sayfasından DMG'yi indirin veya
- Homebrew ile yükleyin:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo, imzalı Sparkle güncellemeleriyle kendini günceller.

### Gereksinimler

- macOS 26 veya daha yenisi. Global Privacy Control için macOS 27 gerekir.

## Kaynaktan derleme

Xcode 27 ve Node.js 22.6+ yüklüyken ([tüm ön koşullar](../../CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # ön koşulları denetler, uygulamanın gereksinimlerini indirir veya derler
make install                    # Release derlemesini /Applications içine kurar, yüklü kopyayı değiştirir
open /Applications/Lilo.app
```

`make bootstrap`, eksik olanları ve nasıl yükleyeceğinizi belirtir. Yalnızca arayüz üzerinde çalışmak
isterseniz Node.js yeterlidir. `make ui-preview`, arayüzü değişiklikleri anında yansıtarak tarayıcınızda
açar ([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

Apple Developer hesabı gerekmez. Kaynaktan derlenen sürümler saptanmış olarak ad hoc imzalanır.
[CONTRIBUTING.md](../../CONTRIBUTING.md#signing), bunun artı ve eksilerini ve ücretsiz Apple ID ile
nasıl imzalayacağınızı açıklar.

## Belgeler

- [docs/](../../docs/README.md): Mimari, hata ayıklama, yerelleştirme, sürüm yayımlama, yapay zekâ ajanları
- [COMPATIBILITY.md](../../COMPATIBILITY.md): Genişletmeler ve siteler için Chrome'dan hâlâ farklı olanlar
- [PRIVACY.md](../../PRIVACY.md): Lilo'nun kendiliğinden yaptığı her istek
- [ROADMAP.md](../../ROADMAP.md): Sunulanlar, sıradakiler ve kapsam dışı hedefler

## Katkıda bulunma

Pull request'lerinizi bekliyoruz. [CONTRIBUTING.md](../../CONTRIBUTING.md), kurulum, geliştirme
akışı ve pull request denetim listesini açıklar. Sorularınızı
[Discussions](https://github.com/Alexays/Lilo/discussions) bölümüne yazın ([SUPPORT.md](../../SUPPORT.md));
güvenlik açıklarını özel olarak bildirin ([SECURITY.md](../../SECURITY.md)). Tüm katılımcılar
[Davranış Kuralları'na](../../CODE_OF_CONDUCT.md) uyar.

## Lisans

MIT; [LICENSE](../../LICENSE) dosyasına bakın. Paketlenen üçüncü taraf bileşenler
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md) dosyasında listelenir.
