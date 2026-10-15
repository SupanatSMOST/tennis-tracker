package cvresult

import (
 "os"
 "testing"
)
func TestSharedGoldenSevenZoneFixture(t *testing.T){b,err:=os.ReadFile("../../../shared/fixtures/golden_bounce_events_7zones.json");if err!=nil{t.Fatal(err)};r,err:=Decode(b);if err!=nil{t.Fatal(err)};zones:=map[string]bool{};for _,e:=range r.Events{if e.Zone!=nil{zones[*e.Zone]=true}};if len(zones)!=7{t.Fatalf("fixture has %d zones, want 7: %#v",len(zones),zones)}}
