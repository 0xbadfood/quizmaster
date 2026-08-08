from __future__ import annotations

from typing import Any


SEED_CATALOG: list[dict[str, Any]] = [
    {
        "slug": "animals",
        "name": "Animals",
        "description": "Wild and domestic animals, their features, habitats, and behavior.",
        "age_min": 5,
        "age_max": 8,
        "objects": [
            ("lion", "Lion", "Manes, roars, prides, and life on the savanna."),
            ("elephant", "Elephant", "Trunks, tusks, families, and communication."),
            ("giraffe", "Giraffe", "Long necks, spotted coats, and treetop feeding."),
            ("tiger", "Tiger", "Striped coats, stealth, habitats, and strong senses."),
            ("monkey", "Monkey", "Climbing, social groups, hands, and varied diets."),
        ],
    },
    {
        "slug": "birds",
        "name": "Birds",
        "description": "Bird identification, feathers, beaks, nests, flight, and calls.",
        "age_min": 5,
        "age_max": 8,
        "objects": [
            ("peacock", "Peacock", "Colorful tail feathers and courtship displays."),
            ("parrot", "Parrot", "Curved beaks, bright feathers, and sound imitation."),
            ("owl", "Owl", "Night vision, silent flight, and hunting adaptations."),
            ("penguin", "Penguin", "Swimming birds, colonies, and cold habitats."),
            ("flamingo", "Flamingo", "Pink feathers, long legs, and filter feeding."),
        ],
    },
    {
        "slug": "food",
        "name": "Food",
        "description": "Fruits, vegetables, familiar meals, nutrition, and food origins.",
        "age_min": 5,
        "age_max": 8,
        "objects": [
            ("apple", "Apple", "Parts of an apple, orchards, colors, and uses."),
            ("banana", "Banana", "Peels, bunches, tropical growing, and nutrition."),
            ("carrot", "Carrot", "Root vegetables, plant growth, color, and crunch."),
            ("pizza", "Pizza", "Ingredients, preparation, shapes, and toppings."),
            ("watermelon", "Watermelon", "Rinds, seeds, vines, and juicy fruit."),
        ],
    },
    {
        "slug": "vehicles",
        "name": "Vehicles",
        "description": "Road, rail, air, and work vehicles and the jobs they perform.",
        "age_min": 5,
        "age_max": 8,
        "objects": [
            ("fire-truck", "Fire Truck", "Emergency equipment, ladders, lights, and firefighters."),
            ("school-bus", "School Bus", "Safe travel, stops, signals, and passengers."),
            ("excavator", "Excavator", "Tracks, booms, buckets, digging, and construction."),
            ("airplane", "Airplane", "Wings, engines, pilots, airports, and flight."),
            ("train", "Train", "Tracks, engines, carriages, stations, and transport."),
        ],
    },
    {
        "slug": "space",
        "name": "Space",
        "description": "The solar system, space travel, observation, and exploration.",
        "age_min": 6,
        "age_max": 9,
        "objects": [
            ("sun", "Sun", "Our star, daylight, heat, and the solar system."),
            ("moon", "Moon", "Phases, craters, orbit, and lunar exploration."),
            ("earth", "Earth", "Oceans, continents, atmosphere, and life."),
            ("astronaut", "Astronaut", "Space suits, training, microgravity, and missions."),
            ("rocket", "Rocket", "Launches, stages, engines, payloads, and spacecraft."),
        ],
    },
    {
        "slug": "world-history",
        "name": "World History",
        "display_tag": "History",
        "description": "Age-appropriate introductions to places, inventions, and major events.",
        "age_min": 7,
        "age_max": 10,
        "objects": [
            ("egyptian-pyramids", "Egyptian Pyramids", "Ancient builders, pharaohs, tombs, and monuments."),
            ("indus-valley", "Indus Valley", "Planned cities, trade, crafts, and early civilization."),
            ("roman-colosseum", "Roman Colosseum", "Ancient Rome, architecture, and public events."),
            ("great-wall", "Great Wall of China", "Fortifications, watchtowers, geography, and construction."),
            ("moon-landing", "Moon Landing", "Apollo 11, astronauts, spacecraft, and exploration."),
        ],
    },
]
