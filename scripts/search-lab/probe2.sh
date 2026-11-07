set +e
UA='palate-search-lab/1.0'
hf(){ echo "=== $1"; curl -s -m 30 "https://huggingface.co/api/datasets/$1" | python3 -c "
import sys,json
d=json.load(sys.stdin); print('license:',[t for t in d.get('tags',[]) if t.startswith('license')], 'downloads',d.get('downloads'),'updated',d.get('lastModified'))
print('files:',[ (s['rfilename']) for s in d.get('siblings',[])][:12])
cd=d.get('cardData') or {}; print('card keys:',list(cd.keys())[:10])"
  curl -s -m 40 "https://datasets-server.huggingface.co/first-rows?dataset=$1&config=default&split=train" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin); print('cols:',[f['name'] for f in d['features']]); 
  for r in d['rows'][:3]: print(json.dumps(r['row'])[:450])
except Exception as e: print('no preview',e)"
  curl -s -m 40 "https://datasets-server.huggingface.co/size?dataset=$1" | python3 -c "
import sys,json
try: d=json.load(sys.stdin); print('rows:',d['size']['dataset'].get('num_rows'))
except Exception as e: print('no size')"; }
for d in FragDBnet/fragrance-database flossomniferus/fragrantica_corpus scento/fragrance-index; do hf $d; done
echo; echo "######## more HF searches"
for s in sneaker kicks watch watches smartphone phones gsmarena boardgame cereal snacks perfumes cologne; do echo "-- $s"; curl -s -m 30 "https://huggingface.co/api/datasets?search=$s&limit=6&sort=downloads&direction=-1" | python3 -c "import sys,json; [print(' ',d['id'],d.get('downloads'),[t for t in d.get('tags',[]) if t.startswith('license')]) for d in json.load(sys.stdin)]"; done
echo; echo "######## OBF facets"
curl -sL -m 30 -A "$UA" 'https://world.openbeautyfacts.org/facets/categories/perfumes.json?page_size=1' | head -c 300; echo
curl -sL -m 30 -A "$UA" 'https://world.openbeautyfacts.org/cgi/search.pl?search_terms=sauvage&search_simple=1&action=process&json=1&page_size=10&fields=product_name,brands,image_front_small_url,image_url,code' | python3 -c "
import sys,json; d=json.load(sys.stdin); print('count',d.get('count'));
[print(' ',p.get('brands'),'|',p.get('product_name'),'|',(p.get('image_front_small_url') or '')[-40:]) for p in d['products']]"
echo; echo "######## OFF API"
curl -sL -m 40 -A "$UA" 'https://world.openfoodfacts.org/cgi/search.pl?search_terms=takis+fuego&search_simple=1&action=process&json=1&page_size=5&fields=product_name,brands,image_front_small_url,code,unique_scans_n' | head -c 900; echo
curl -sL -m 40 -A "$UA" -D - -o /dev/null 'https://world.openfoodfacts.org/cgi/search.pl?search_terms=takis&search_simple=1&action=process&json=1&page_size=1' | grep -i 'access-control\|HTTP/'
echo; echo "######## Wikidata sample class counts"
wd(){ q="$2"; echo "-- $1"; curl -s -m 75 -A "$UA" -H 'Accept: application/sparql-results+json' --data-urlencode "query=$q" https://query.wikidata.org/sparql | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for b in d['results']['bindings'][:12]: print('  ',' | '.join(v['value'][:70] for v in b.values()))
except Exception as e: print('  FAIL',e)"; }
wd "labels of candidate classes" 'SELECT ?c ?cLabel WHERE { VALUES ?c { wd:Q131746 wd:Q7889 wd:Q131436 wd:Q142714 wd:Q18534542 wd:Q1186620 wd:Q18534542 wd:Q10943 wd:Q178794 wd:Q19723451 wd:Q22698 wd:Q15631401 wd:Q42889 wd:Q1356145 wd:Q34379 wd:Q4830453 wd:Q2095 wd:Q15117302 wd:Q20857 wd:Q7366 } SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } }'
wd "board games by sitelinks" 'SELECT ?itemLabel ?sl WHERE { ?item wdt:P31/wdt:P279* wd:Q131436 . ?item wikibase:sitelinks ?sl . FILTER(?sl>=8) SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } } ORDER BY DESC(?sl) LIMIT 12'
wd "count of board games sl>=5" 'SELECT (COUNT(*) AS ?n) WHERE { ?item wdt:P31/wdt:P279* wd:Q131436 . ?item wikibase:sitelinks ?sl . FILTER(?sl>=5) }'
wd "video games sl>=30 count" 'SELECT (COUNT(*) AS ?n) WHERE { ?item wdt:P31 wd:Q7889 . ?item wikibase:sitelinks ?sl . FILTER(?sl>=30) }'
wd "cheeses" 'SELECT (COUNT(*) AS ?n) WHERE { ?item wdt:P31/wdt:P279* wd:Q10943 . }'
