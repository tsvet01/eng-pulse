import json
import re

opml_data = """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
<head>
  <title>My feeds</title>
</head>
<body>
<outline text="Feeds" title="Feeds">
  <outline title="Crisp's Blog" category="Management" type="rss" xmlUrl="https://blog.crisp.se/feed" />
  <outline title="MBI Deep Dives" category="News" type="rss" xmlUrl="https://mbi-deepdives.com/feed/" />
  <outline title="Management Blog" category="Management" type="rss" xmlUrl="https://managementblog.org/feed/" />
  <outline title="RescueTime Blog"  type="rss" xmlUrl="https://blog.rescuetime.com/feed" />
  <outline title="JD Meier" category="Management" type="rss" xmlUrl="https://jdmeier.com/feed/" />
  <outline title="Herding Cats" category="Management" type="rss" xmlUrl="https://herdingcats.typepad.com/my_weblog/atom.xml" />
  <outline title="Записки инвестора" category="Business" type="rss" xmlUrl="https://fintraining.livejournal.com/data/rss" />
  <outline title="Маркетинг В Маленьком Городе"  type="rss" xmlUrl="http://davydov.blogspot.com/feeds/posts/default?alt=rss" />
  <outline title="JIM HIGHSMITH" category="HighPriority" type="rss" xmlUrl="http://feeds.feedburner.com/AgileImagineering" />
  <outline title="Umputun тут был" category="HighPriority" type="rss" xmlUrl="http://feeds.feedburner.com/p-umputun" />
  <outline title="ИТ с высоты птичьего полета /блог Сергея Орлика/"  type="rss" xmlUrl="http://sorlik.blogspot.com/feeds/posts/default" />
  <outline title="Алёна C++"  type="rss" xmlUrl="http://alenacpp.blogspot.com/feeds/posts/default" />
  <outline title="management craft" category="Management" type="rss" xmlUrl="http://feeds.feedburner.com/ManagementCraft" />
  <outline title="Записки дебианщика"  type="rss" xmlUrl="http://mydebianblog.blogspot.com/feeds/posts/default" />
  <outline title="JIM HIGHSMITH" category="Management" type="rss" xmlUrl="http://jimhighsmith.com/feed/" />
  <outline title="gerdov" category="Management" type="rss" xmlUrl="http://gerdov.blogspot.com/feeds/posts/default" />
  <outline title="ру/Ководство"  type="rss" xmlUrl="http://www.artlebedev.ru/kovodstvo/sections/kovodstvo.rdf" />
  <outline title="Zenegment" category="Management" type="rss" xmlUrl="http://cartmendum.livejournal.com/data/rss" />
  <outline title="letchikleha" category="HighPriority" type="rss" xmlUrl="http://letchikleha.livejournal.com/data/atom" />
  <outline title="Gaperton's blog" category="HighPriority" type="rss" xmlUrl="http://gaperton.livejournal.com/data/atom" />
  <outline title="C++ – Типизированный язык программирования"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/cpp/" />
  <outline title="Techmind`s blog"  type="rss" xmlUrl="http://techmnd.blogspot.com/feeds/posts/default?alt=rss" />
  <outline title="Осиное гнездо белой эмиграции"  type="rss" xmlUrl="http://chich8.livejournal.com/data/rss" />
  <outline title="GTD – Методика повышения личной эффективности"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/gtd/" />
  <outline title="Russian MBA Community"  type="rss" xmlUrl="http://community.livejournal.com/rus_mba/data/rss" />
  <outline title="Проектирование и рефакторинг – Реорганизация кода"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/refactoring/" />
  <outline title="AgileRussia" category="Management" type="rss" xmlUrl="http://agilerussia.ru/feed/rss/" />
  <outline title="La ragazza con la valigia"  type="rss" xmlUrl="http://taquino.livejournal.com/data/rss" />
  <outline title="Домашняя страница AbilityCash"  type="rss" xmlUrl="http://dervish.ru/rss.xml" />
  <outline title="Agile – Гибкая методология разработки"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/agile/" />
  <outline title="Управление проектами – Как заставить всё работать"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/pm/" />
  <outline title="PM Blog"  type="rss" xmlUrl="http://www.appfluence.com/productivity/feed/" />
  <outline title="Психология и психотерапия для жизни" category="Psy" type="rss" xmlUrl="http://www.centrresheniy.ru/feed/" />
  <outline title="Управление e-commerce – Электронная коммерция и всё, что с ней связано"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/ecommerce/" />
  <outline title="Биографии гиков – Истории жизни замечательных людей"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/it_bigraphy/" />
  <outline title="Высокая производительность – Методы получения высокой производительности систем"  type="rss" xmlUrl="http://habrahabr.ru/rss/blogs/hi/" />
  <outline title="Верь в себя и ничего не бойся" category="Friends" type="rss" xmlUrl="http://skitalac.livejournal.com/data/rss" />
  <outline title="Daniel Doyon"  type="rss" xmlUrl="https://readwise-community.ghost.io/2defd8e965b87487102ef0c6db1880/rss/?ref=daniel-doyon-newsletter&attribution_id=6394b87adc93de003d6efbe6&attribution_type=post" />
  <outline title="Радислав Гандапас" category="Management" type="rss" xmlUrl="http://feeds.feedburner.com/RadislavGandapas" />
  <outline title="MIT Sloan Management Review"  type="rss" xmlUrl="http://feeds.feedburner.com/mitsmr" />
  <outline title="MBI Deep Dives"  type="rss" xmlUrl="https://www.mbi-deepdives.com/rss/" />
  <outline title="Just So Blogger" category="Business" type="rss" xmlUrl="http://www.justsoblogger.com/feed/" />
  <outline title="Hog Bay Software" category="News" type="rss" xmlUrl="https://www.hogbaysoftware.com/feed/feed.xml" />
  <outline title="charity.wtf"  type="rss" xmlUrl="https://charity.wtf/feed/" />
  <outline title="Dan Luu"  type="rss" xmlUrl="https://politepol.com/fd/l7VasgAQAWB6" />
  <outline title="Hudson River Trading" category="News" type="rss" xmlUrl="https://www.hudsonrivertrading.com/feed/" />
  <outline title="Martin Fowler" category="Software Engineering" type="rss" xmlUrl="https://martinfowler.com/feed.atom" />
  <outline title="Simon Willison's Weblog"  type="rss" xmlUrl="https://simonwillison.net/atom/everything/" />
  <outline title="Fazal Majid's low-intensity blog"  type="rss" xmlUrl="http://www.majid.info/mylos/weblog/rss.xml" />
  <outline title="seangoedecke.com RSS feed"  type="rss" xmlUrl="https://www.seangoedecke.com/rss.xml" />
  <outline title="Pragmatic Programming Techniques" category="HighPriority" type="rss" xmlUrl="http://horicky.blogspot.com/feeds/posts/default?alt=rss" />
  <outline title="Артемий Лебедев"  type="rss" xmlUrl="https://teletype.in/rss/temalebedev" />
  <outline title="Лучшие статьи за неделю / DevOps / Хабр"  type="rss" xmlUrl="https://habr.com/ru/rss/hubs/devops/articles/top/weekly/?fl=ru" />
  <outline title="Лучшие статьи за неделю / Искусственный интеллект / Хабр"  type="rss" xmlUrl="https://habr.com/ru/rss/hubs/artificial_intelligence/articles/top/weekly/?fl=ru" />
  <outline title="Лучшие статьи за неделю / Тестирование IT-систем / Хабр"  type="rss" xmlUrl="https://habr.com/ru/rss/hubs/it_testing/articles/top/weekly/?fl=ru" />
  <outline title="Health & Fitness Archives | The Art of Manliness"  type="rss" xmlUrl="https://www.artofmanliness.com/health-fitness/feed/" />
  <outline title="Style Archives | The Art of Manliness"  type="rss" xmlUrl="https://www.artofmanliness.com/style/feed/" />
  <outline title="Джедайский Клуб: Новые посты"  type="rss" xmlUrl="http://club.mnogosdelal.ru/posts.rss" />
</outline>
</body>
</opml>
"""

candidates = []
for line in opml_data.splitlines():
    if 'xmlUrl=' in line:
        # Simple regex to extract title and xmlUrl
        title_match = re.search(r'title="([^"]+)"', line)
        url_match = re.search(r'xmlUrl="([^"]+)"', line)
        
        if title_match and url_match:
            candidates.append({
                "name": title_match.group(1),
                "type": "rss",
                "url": url_match.group(1)
            })

with open("candidates.json", "w") as f:
    json.dump(candidates, f, indent=2)

print(f"Extracted {len(candidates)} candidates.")